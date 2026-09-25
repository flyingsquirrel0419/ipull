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

    public enum SessionCheck: Equatable {
        case idle, checking, valid, unverified
    }
    /// Result of the once-per-launch check that Apple still accepts the
    /// stored token.
    @Published public private(set) var sessionCheck: SessionCheck = .idle
    /// Shown once when the stored session turned out to be dead.
    @Published public var sessionNotice: String?

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
                relativeFilePath: relative,
                iconURL: record.iconURL
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
                await self.verifySession()
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
                sessionCheck = .valid
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

    /// Apple rejected the stored token (password changed, signed out
    /// elsewhere, expired). Drop it so the UI stops claiming to be signed in.
    public func handleServiceError(_ error: AppStoreError) {
        guard error.requiresReauthentication, session != nil else { return }
        Log.info(.auth, "Apple rejected the stored session; signing out locally")
        sessionNotice = "Your Apple Account session has ended. Sign in again to browse versions and download."
        Task { await signOut() }
    }

    /// Once per launch, ask Apple whether the stored token still works.
    /// The probe is a download-product lookup for an app this account has
    /// already downloaded: Apple answers it with the file when the token is
    /// good and with "sign in required" (2042) when it is not. An app the
    /// account doesn't own is useless as a probe — Apple answers "license
    /// not found" (9610) before it checks the token, which is how the first
    /// version of this check reported a dead session as valid.
    func verifySession() async {
        guard let session, sessionCheck == .idle else { return }
        sessionCheck = .checking
        let candidates = ownedAppIDs()
        Log.info(.auth, "verifying stored session with Apple (\(candidates.count) owned app probes)")
        for appID in candidates.prefix(3) {
            let probe = AppStoreApp(id: appID, bundleID: "", name: "")
            do {
                _ = try await client.downloadMetadata.downloadMetadata(app: probe, session: session, externalVersionID: nil)
                sessionCheck = .valid
                Log.info(.auth, "stored session is valid")
                return
            } catch let error as AppStoreError where error.requiresReauthentication {
                sessionCheck = .idle
                handleServiceError(error)
                return
            } catch let error as AppStoreError where error == .appNotOwned {
                continue // not a usable probe; try the next app
            } catch {
                break
            }
        }
        sessionCheck = .unverified
        Log.info(.auth, "session check inconclusive")
    }

    private static let ownedAppsKey = "owned-app-ids"

    /// Record an app Apple just served a download for, as a future probe.
    /// Kept separately because a Library copy is optional.
    public func rememberOwnedApp(_ appID: Int64) {
        var ids = (UserDefaults.standard.array(forKey: Self.ownedAppsKey) as? [Int64]) ?? []
        ids.removeAll { $0 == appID }
        ids.insert(appID, at: 0)
        UserDefaults.standard.set(Array(ids.prefix(10)), forKey: Self.ownedAppsKey)
    }

    /// App IDs this account has downloaded, newest first.
    private func ownedAppIDs() -> [Int64] {
        var ids = (UserDefaults.standard.array(forKey: Self.ownedAppsKey) as? [Int64]) ?? []
        ids += downloadManager.records.filter { $0.state == .completed }.reversed().map(\.appID)
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<LibraryItem>(sortBy: [SortDescriptor(\.downloadedAt, order: .reverse)])
        ids += ((try? context.fetch(descriptor)) ?? []).map(\.appID)
        var seen = Set<Int64>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Fill in artwork for rows saved before icons were stored.
    public func iconURL(forAppID appID: Int64) async -> URL? {
        let country = session?.countryCode ?? "us"
        return try? await client.search.lookup(appID: appID, countryCode: country).iconURL
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
        sessionCheck = .idle
        needsTwoFactorCode = false
    }
}
