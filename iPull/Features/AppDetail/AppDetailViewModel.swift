import Foundation
import AppStoreCore

@MainActor
final class AppDetailViewModel: ObservableObject {
    enum State: Equatable {
        case loading, loaded
        case failed(String)
    }

    enum VersionState: Equatable {
        case loading
        case requiresSignIn
        case unavailable(String)
        case loaded([AppStoreVersion])
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var versionState: VersionState = .loading
    @Published private(set) var app: AppStoreApp?
    @Published private(set) var selectedVersion: AppStoreVersion?
    @Published private(set) var downloadStatus: String?
    @Published private(set) var canDownload = false
    /// True while the download URL is being resolved with Apple.
    @Published private(set) var isResolving = false

    func load(appID: Int64, environment: AppEnvironment) async {
        // Keep the loaded page on screen when re-running after sign-in.
        if app?.id != appID { state = .loading }
        let country = environment.session?.countryCode ?? "us"
        do {
            let app = try await environment.client.search.lookup(appID: appID, countryCode: country)
            self.app = app
            state = .loaded
            await loadVersions(app: app, environment: environment)
        } catch is CancellationError {
            return
        } catch let error as AppStoreError {
            state = .failed(error.userMessage)
        } catch {
            state = .failed(AppStoreError.unknown("lookup").userMessage)
        }
    }

    private func loadVersions(app: AppStoreApp, environment: AppEnvironment) async {
        guard let session = environment.session else {
            versionState = .requiresSignIn
            canDownload = false
            return
        }
        versionState = .loading
        do {
            let result = try await environment.client.versions.listVersions(app: app, session: session)
            var versions = result.versions

            // Resolve display versions for the first few (latest first).
            for index in versions.prefix(5).indices {
                if let resolved = try? await environment.client.versions.versionMetadata(
                    app: app, session: session, externalVersionID: versions[index].externalVersionID
                ) {
                    versions[index] = AppStoreVersion(
                        displayVersion: resolved.displayVersion,
                        externalVersionID: versions[index].externalVersionID,
                        releaseDate: resolved.releaseDate,
                        isLatest: versions[index].isLatest
                    )
                }
            }

            versionState = .loaded(versions)
            selectedVersion = versions.first(where: \.isLatest) ?? versions.first
            canDownload = selectedVersion != nil
        } catch is CancellationError {
            return
        } catch let error as AppStoreError {
            switch error {
            case .sessionExpired, .authenticationRequired:
                versionState = .requiresSignIn
                environment.handleServiceError(error)
            case .appNotOwned, .purchaseRequired:
                // Try to acquire a free license, then retry once.
                await acquireAndRetry(app: app, environment: environment, session: session)
            default:
                versionState = .unavailable(error.userMessage)
            }
        } catch {
            versionState = .unavailable(AppStoreError.unknown("versions").userMessage)
        }
    }

    private func acquireAndRetry(app: AppStoreApp, environment: AppEnvironment, session: AppleAccountSession) async {
        do {
            try await environment.client.purchase.acquireLicense(app: app, session: session)
            await loadVersions(app: app, environment: environment)
        } catch let error as AppStoreError {
            versionState = error.requiresReauthentication ? .requiresSignIn : .unavailable(error.userMessage)
            environment.handleServiceError(error)
        } catch {
            versionState = .unavailable(AppStoreError.appNotOwned.userMessage)
        }
    }

    func select(_ version: AppStoreVersion) {
        selectedVersion = version
        canDownload = true
    }

    /// Resolve and queue the selected version. Returns true once queued,
    /// which is the moment the UI plays the fly-to-Downloads animation.
    @discardableResult
    func download(environment: AppEnvironment, destinationBookmark: Data?) async -> Bool {
        guard let app, let session = environment.session else {
            downloadStatus = AppStoreError.authenticationRequired.userMessage
            return false
        }
        guard let version = selectedVersion else { return false }
        isResolving = true
        defer { isResolving = false }

        // Duplicate detection
        if let existing = environment.storage.existingFile(appID: app.id, version: version.displayVersion ?? version.externalVersionID) {
            // Already in Library: write that copy to the chosen folder instead
            // of downloading the same IPA again.
            if let destinationBookmark,
               let written = try? SaveLocation.export(existing, to: destinationBookmark, move: false) {
                downloadStatus = "Saved to \(written.deletingLastPathComponent().lastPathComponent)."
            } else {
                downloadStatus = "Already downloaded — see Library."
            }
            return false
        }

        // Disk space check
        if let expected = app.fileSizeBytes,
           let free = environment.storage.freeDiskBytes(),
           free < expected {
            downloadStatus = AppStoreError.storageFull.userMessage
            return false
        }

        downloadStatus = nil
        do {
            let metadata = try await environment.client.downloadMetadata.downloadMetadata(
                app: app, session: session,
                externalVersionID: version.isLatest ? nil : version.externalVersionID
            )
            let resolvedVersion = AppStoreVersion(
                displayVersion: metadata.displayVersion ?? version.displayVersion,
                externalVersionID: version.externalVersionID,
                releaseDate: version.releaseDate,
                isLatest: version.isLatest
            )
            Log.info(.download, "download URL resolved; queueing (folder=\(destinationBookmark != nil))")
            environment.rememberOwnedApp(app.id)
            environment.downloadManager.enqueue(app: app, version: resolvedVersion, cdnURL: metadata.url,
                                                destinationBookmark: destinationBookmark)
            return true
        } catch let error as AppStoreError {
            Log.error(.download, "download URL resolution failed: \(error)")
            downloadStatus = error.userMessage
            environment.handleServiceError(error)
            return false
        } catch {
            Log.error(.download, "download URL resolution failed: \(String(describing: type(of: error)))")
            downloadStatus = AppStoreError.downloadFailed("resolve").userMessage
            return false
        }
    }
}
