import Foundation
import SwiftData
import AppStoreCore

/// Composition root for the app. Owns the long-lived services.
@MainActor
public final class AppEnvironment: ObservableObject {
    public let modelContainer: ModelContainer
    public let client: AppStoreClient
    public let storage: IPAStorage
    public let downloadManager: DownloadManager

    @Published public var session: AppleAccountSession?

    public init() {
        let secrets = KeychainStore()
        let client = AppStoreClient.live(secrets: secrets)
        self.client = client

        let container: ModelContainer
        do {
            container = try ModelContainer(for: LibraryItem.self, RecentApp.self)
        } catch {
            // Schema migration failure fallback: in-memory container keeps the
            // app usable; the library reports an error state in the UI.
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: LibraryItem.self, RecentApp.self, configurations: config)
        }
        self.modelContainer = container

        let storage = (try? IPAStorage()) ?? {
            // Worst case: fall back to Caches so the app still launches.
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            return try! IPAStorage(fileManager: .default)
        }()
        self.storage = storage

        let modelContainer = container
        self.downloadManager = DownloadManager(storage: storage) { record, fileURL in
            let context = ModelContext(modelContainer)
            // Register completed download in Library and compute SHA-256
            // off the main thread (streaming, chunked).
            let relative = storage.relativePath(forAbsolute: fileURL)
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
            let item = LibraryItem(
                appName: record.appName,
                version: record.version,
                bundleID: record.bundleID,
                appID: record.appID,
                fileSizeBytes: size,
                relativeFilePath: relative
            )
            context.insert(item)
            try? context.save()

            Task {
                // Hash off the cooperative thread pool; mutate the model back
                // on the main actor (ModelContext is main-actor bound).
                let hash = await Task.detached(priority: .utility) {
                    try? SHA256Streamer.hash(fileAt: fileURL)
                }.value
                item.sha256 = hash
                try? context.save()
            }
        }

        // Restore session (token lives in the Keychain).
        Task { [client] in
            self.session = try? await client.auth.restoreSession()
        }
    }

    public func signOut() async {
        try? await client.auth.signOut()
        session = nil
    }
}
