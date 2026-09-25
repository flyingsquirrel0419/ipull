import Foundation

/// State of a download task, persisted so queue/recovery survive restarts.
public enum DownloadState: String, Codable, Sendable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}

/// Persistable record of a download task (Codable mirror kept on disk as
/// JSON so state restores after the system re-launches the app for a
/// background URLSession event).
public struct DownloadRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var appID: Int64
    public var appName: String
    public var bundleID: String
    public var version: String
    public var externalVersionID: String?
    public var state: DownloadState
    public var bytesDownloaded: Int64
    public var totalBytes: Int64
    public var failureReason: String?
    public var createdAt: Date
    /// Optional so records persisted by older builds still decode.
    public var iconURL: URL?

    public init(
        id: UUID = UUID(),
        appID: Int64,
        appName: String,
        bundleID: String,
        version: String,
        externalVersionID: String? = nil,
        state: DownloadState = .queued,
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64 = 0,
        failureReason: String? = nil,
        createdAt: Date = .now,
        iconURL: URL? = nil
    ) {
        self.id = id
        self.appID = appID
        self.appName = appName
        self.bundleID = bundleID
        self.version = version
        self.externalVersionID = externalVersionID
        self.state = state
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.failureReason = failureReason
        self.createdAt = createdAt
        self.iconURL = iconURL
    }

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesDownloaded) / Double(totalBytes))
    }
}
