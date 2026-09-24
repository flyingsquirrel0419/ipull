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
    /// True while a sign-in or sign-out is in flight; drives UI progress.
    @Published public private(set) var isAuthenticating = false
    /// True after Apple answered "verification code required". While set the
    /// caller must resubmit the same credentials with a code appended.
    @Published public private(set) var needsTwoFactorCode = false
    @Published public private(set) var authenticationProgress: AuthenticationProgress?
    @Published public private(set) var sapDownloadStartedAt: Date?

    public init() {
        let secrets = KeychainStore()
        let (progressStream, progressContinuation) = AsyncStream.makeStream(
            of: AuthenticationProgress.self, bufferingPolicy: .bufferingNewest(1))
        let client = AppStoreClient.live(secrets: secrets) { progress in
            progressContinuation.yield(progress)
        }
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

        Task {
            for await progress in progressStream {
                if case .downloadingAssets = progress, self.sapDownloadStartedAt == nil {
                    self.sapDownloadStartedAt = Date()
                }
                self.authenticationProgress = progress
            }
        }

        // Restore session (token lives in the Keychain). A corrupt blob
        // fails to decode — treat that as signed out and drop it.
        Task { [client] in
            do {
                let restored = try await client.auth.restoreSession()
                if !self.isAuthenticating && self.session == nil {
                    self.session = restored
                }
            } catch {
                Log.error(.auth, "stored session unreadable; clearing it")
                if !self.isAuthenticating && self.session == nil {
                    try? await client.auth.signOut()
                }
            }
        }
    }

    /// Sign in with credentials held only for the duration of this call.
    /// The password is a local value, never a stored property, so it cannot
    /// outlive the attempt, be observed by SwiftUI, or reach logs. On
    /// .twoFactorRequired the caller keeps its own copy of the password and
    /// calls this again with the six-digit code.
    @discardableResult
    public func signIn(email: String, password: String, twoFactorCode: String? = nil) async -> Result<AppleAccountSession, AppStoreError> {
        authenticationProgress = nil
        sapDownloadStartedAt = nil
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let result = try await client.auth.signIn(email: email, password: password, twoFactorCode: twoFactorCode)
            switch result {
            case .success(let session):
                self.session = session
                needsTwoFactorCode = false
                return .success(session)
            case .twoFactorRequired:
                Log.info(.auth, "two-factor required; prompting for code")
                needsTwoFactorCode = true
                Log.info(.auth, "two-factor prompt shown")
                return .failure(.twoFactorRequired)
            }
        } catch let error as AppStoreError {
            if error.requiresReauthentication && error != .invalidTwoFactorCode {
                // A dead token must not survive a failed sign-in.
                try? await client.auth.signOut()
                session = nil
            }
            if error != .invalidTwoFactorCode {
                needsTwoFactorCode = false
            }
            return .failure(error)
        } catch {
            needsTwoFactorCode = false
            return .failure(.unknown(String(describing: type(of: error))))
        }
    }

    /// Abandon a pending two-factor prompt (user tapped "Use a different
    /// account" or edited the email). No network call; just UI state.
    public func cancelTwoFactor() {
        needsTwoFactorCode = false
    }

    public func signOut() async {
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            try await client.auth.signOut()
        } catch {
            // Keychain deletion failures leave a stale token behind; still
            // drop the in-memory session so the app behaves signed out.
            Log.error(.auth, "sign-out: token removal failed (\(String(describing: type(of: error))))")
        }
        session = nil
        needsTwoFactorCode = false
    }
}
