import Foundation
import AppStoreCore

/// Live progress snapshot published to the UI.
public struct DownloadProgress: Sendable, Equatable {
    public let bytesDownloaded: Int64
    public let totalBytes: Int64
    public let bytesPerSecond: Double

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesDownloaded) / Double(totalBytes))
    }
}

/// Manages a queue of IPA downloads on top of URLSessionDownloadTask.
///
/// Design:
/// - Downloads stream to disk (never into memory).
/// - State is persisted after every transition so queue/recovery survive
///   app termination.
/// - Resume data from cancelled/failed tasks is retained for retry.
/// - A background session is used so downloads can complete while the app
///   is suspended; the system re-launches the app and restoreState
///   reconciles records.
@MainActor
public final class DownloadManager: NSObject, ObservableObject {
    public static let backgroundSessionID = "com.ipull.app.background-downloads"

    @Published public private(set) var records: [DownloadRecord] = []
    @Published public private(set) var progress: [UUID: DownloadProgress] = [:]

    private let storage: IPAStorage
    private let onCompleted: @Sendable (DownloadRecord, URL) async -> Void
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var resumeData: [UUID: Data] = [:]
    private var lastSample: [UUID: (date: Date, bytes: Int64)] = [:]
    private var pendingURLs: [UUID: URL] = [:]
    private var session: URLSession!

    private var stateFileURL: URL {
        storage.rootURL.deletingLastPathComponent().appendingPathComponent("download-state.json")
    }

    public init(storage: IPAStorage, onCompleted: @escaping @Sendable (DownloadRecord, URL) async -> Void) {
        self.storage = storage
        self.onCompleted = onCompleted
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        restoreState()
    }

    // MARK: - Queue

    @discardableResult
    public func enqueue(app: AppStoreApp, version: AppStoreVersion, cdnURL: URL) -> DownloadRecord {
        let record = DownloadRecord(
            appID: app.id, appName: app.name, bundleID: app.bundleID,
            version: version.displayVersion ?? version.externalVersionID,
            externalVersionID: version.externalVersionID, state: .queued,
            totalBytes: app.fileSizeBytes ?? 0
        )
        pendingURLs[record.id] = cdnURL
        records.append(record)
        persistState()
        startNextIfPossible()
        return record
    }

    public func cancel(_ id: UUID) {
        if let task = tasks[id] {
            task.cancel { [weak self] data in
                Task { @MainActor in self?.resumeData[id] = data }
            }
        }
        update(id) { $0.state = .cancelled }
        startNextIfPossible()
    }

    public func retry(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }),
              record.state == .failed || record.state == .cancelled,
              pendingURLs[id] != nil
        else { return }
        update(id) { $0.state = .queued; $0.failureReason = nil }
        startNextIfPossible()
    }

    public func remove(_ id: UUID) {
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        resumeData.removeValue(forKey: id)
        pendingURLs.removeValue(forKey: id)
        records.removeAll { $0.id == id }
        persistState()
    }

    private func startNextIfPossible() {
        let activeCount = records.filter { $0.state == .downloading }.count
        guard activeCount < 2, // at most 2 concurrent — big files on mobile radio
              let next = records.first(where: { $0.state == .queued }),
              let url = pendingURLs[next.id]
        else { return }
        start(record: next, url: url)
    }

    private func start(record: DownloadRecord, url: URL) {
        let task: URLSessionDownloadTask
        if let data = resumeData[record.id] {
            task = session.downloadTask(withResumeData: data)
            resumeData.removeValue(forKey: record.id)
        } else {
            task = session.downloadTask(with: url)
        }
        task.taskDescription = record.id.uuidString
        tasks[record.id] = task
        task.resume()
        update(record.id) { $0.state = .downloading }
    }

    private func update(_ id: UUID, _ mutate: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutate(&records[index])
        persistState()
    }

    // MARK: - Persistence

    private func persistState() {
        let persistable = records.filter { $0.state != .completed }
        guard let data = try? JSONEncoder().encode(persistable) else { return }
        try? data.write(to: stateFileURL, options: .atomic)
    }

    /// Reconcile after cold start / system relaunch for background events.
    public func restoreState() {
        guard let data = try? Data(contentsOf: stateFileURL),
              let restored = try? JSONDecoder().decode([DownloadRecord].self, from: data)
        else { return }
        records = restored
        for record in records where record.state == .downloading && tasks[record.id] == nil {
            update(record.id) { $0.state = .queued }
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        guard let idString = downloadTask.taskDescription, let id = UUID(uuidString: idString) else { return }
        // Move immediately in this callback — the temp file is deleted when
        // the delegate returns. Stream via FileManager, never load into RAM.
        Task { @MainActor in
            guard let record = self.records.first(where: { $0.id == id }) else { return }
            let destination = self.storage.fileURL(
                appName: record.appName, appID: record.appID, version: record.version
            )
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: location, to: destination)
                self.update(id) { $0.state = .completed }
                self.tasks.removeValue(forKey: id)
                self.pendingURLs.removeValue(forKey: id)
                self.progress.removeValue(forKey: id)
                await self.onCompleted(record, destination)
                self.startNextIfPossible()
            } catch {
                self.update(id) {
                    $0.state = .failed
                    $0.failureReason = AppStoreError.fileWriteFailed.userMessage
                }
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let idString = downloadTask.taskDescription, let id = UUID(uuidString: idString) else { return }
        Task { @MainActor in
            let now = Date()
            var speed: Double = 0
            if let last = self.lastSample[id] {
                let dt = now.timeIntervalSince(last.date)
                if dt > 0.25 {
                    speed = Double(totalBytesWritten - last.bytes) / dt
                    self.lastSample[id] = (now, totalBytesWritten)
                } else if let existing = self.progress[id] {
                    speed = existing.bytesPerSecond
                }
            } else {
                self.lastSample[id] = (now, totalBytesWritten)
            }
            self.progress[id] = DownloadProgress(
                bytesDownloaded: totalBytesWritten,
                totalBytes: max(totalBytesExpectedToWrite, 0),
                bytesPerSecond: speed
            )
            self.update(id) {
                $0.bytesDownloaded = totalBytesWritten
                if totalBytesExpectedToWrite > 0 { $0.totalBytes = totalBytesExpectedToWrite }
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        guard let idString = task.taskDescription, let id = UUID(uuidString: idString) else { return }
        guard let error else { return } // success handled in didFinishDownloadingTo
        let nsError = error as NSError
        Task { @MainActor in
            if let data = nsError.userInfo["NSURLSessionDownloadTaskResumeData"] as? Data {
                self.resumeData[id] = data
            }
            if (error as? URLError)?.code == .cancelled {
                return // cancel() already updated state
            }
            self.update(id) {
                $0.state = .failed
                $0.failureReason = AppStoreError.downloadFailed("network").userMessage
            }
            self.tasks.removeValue(forKey: id)
            self.startNextIfPossible()
        }
    }
}
