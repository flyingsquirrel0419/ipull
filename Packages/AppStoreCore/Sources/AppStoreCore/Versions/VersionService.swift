import Foundation

public struct VersionListResult: Sendable, Equatable {
    public let versions: [AppStoreVersion]
    public let latestExternalVersionID: String

    public init(versions: [AppStoreVersion], latestExternalVersionID: String) {
        self.versions = versions
        self.latestExternalVersionID = latestExternalVersionID
    }
}

public protocol VersionServicing: Sendable {
    /// List downloadable versions for an app. Requires an owned license;
    /// throws AppStoreError.appNotOwned / .sessionExpired otherwise.
    func listVersions(app: AppStoreApp, session: AppleAccountSession) async throws -> VersionListResult
    /// Resolve display version + release date for a pinned version.
    func versionMetadata(app: AppStoreApp, session: AppleAccountSession, externalVersionID: String) async throws -> AppStoreVersion
}

public final class VersionService: VersionServicing, @unchecked Sendable {
    private let http: HTTPClient
    private let bagProvider: BagProviding
    private let guidProvider: @Sendable () throws -> String

    public init(http: HTTPClient, bagProvider: BagProviding, guidProvider: @escaping @Sendable () throws -> String) {
        self.http = http
        self.bagProvider = bagProvider
        self.guidProvider = guidProvider
    }

    public func listVersions(app: AppStoreApp, session: AppleAccountSession) async throws -> VersionListResult {
        let guid = try guidProvider()
        let item = try await DownloadProductRequest.send(
            http: http, bagProvider: bagProvider, session: session,
            appID: app.id, guid: guid, externalVersionID: nil
        )

        guard let rawIDs = item.metadata["softwareVersionExternalIdentifiers"] as? [Any] else {
            throw AppStoreError.versionUnavailable
        }
        // Apple lists external version IDs oldest first and they grow over
        // time; show newest first so the latest builds lead the list and get
        // their display versions resolved.
        let ids = rawIDs.map { String(describing: $0) }
            .sorted { (Int64($0) ?? 0) > (Int64($1) ?? 0) }
        let latest = item.metadata["softwareVersionExternalIdentifier"].map { String(describing: $0) }
            ?? ids.first ?? ""

        let versions = ids.map { id in
            AppStoreVersion(displayVersion: nil, externalVersionID: id, isLatest: id == latest)
        }
        return VersionListResult(versions: versions, latestExternalVersionID: latest)
    }

    public func versionMetadata(app: AppStoreApp, session: AppleAccountSession, externalVersionID: String) async throws -> AppStoreVersion {
        let guid = try guidProvider()
        let item = try await DownloadProductRequest.send(
            http: http, bagProvider: bagProvider, session: session,
            appID: app.id, guid: guid, externalVersionID: externalVersionID
        )

        let display = item.metadata["bundleShortVersionString"] as? String
        let releaseDate: Date? = (item.metadata["releaseDate"] as? String).flatMap { date in
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.date(from: date) ?? ISO8601DateFormatter().date(from: date)
        }
        return AppStoreVersion(
            displayVersion: display,
            externalVersionID: externalVersionID,
            releaseDate: releaseDate,
            isLatest: false
        )
    }
}
