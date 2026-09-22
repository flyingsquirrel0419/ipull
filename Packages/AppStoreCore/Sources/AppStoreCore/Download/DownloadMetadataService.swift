import Foundation

public struct IPADownloadMetadata: Sendable, Equatable {
    public let url: URL
    public let displayVersion: String?
    public let fileSizeBytes: Int64?

    public init(url: URL, displayVersion: String?, fileSizeBytes: Int64?) {
        self.url = url
        self.displayVersion = displayVersion
        self.fileSizeBytes = fileSizeBytes
    }
}

public protocol DownloadMetadataServicing: Sendable {
    /// Resolve the Apple CDN URL for a given app + version.
    func downloadMetadata(
        app: AppStoreApp,
        session: AppleAccountSession,
        externalVersionID: String?
    ) async throws -> IPADownloadMetadata
}

public final class DownloadMetadataService: DownloadMetadataServicing, @unchecked Sendable {
    private let http: HTTPClient
    private let bagProvider: BagProviding
    private let guidProvider: @Sendable () throws -> String

    public init(http: HTTPClient, bagProvider: BagProviding, guidProvider: @escaping @Sendable () throws -> String) {
        self.http = http
        self.bagProvider = bagProvider
        self.guidProvider = guidProvider
    }

    public func downloadMetadata(
        app: AppStoreApp,
        session: AppleAccountSession,
        externalVersionID: String?
    ) async throws -> IPADownloadMetadata {
        let guid = try guidProvider()
        let item = try await DownloadProductRequest.send(
            http: http, bagProvider: bagProvider, session: session,
            appID: app.id, guid: guid, externalVersionID: externalVersionID
        )

        guard let url = item.downloadURL else {
            throw AppStoreError.downloadURLUnavailable
        }

        let size = item.metadata["fileSizeBytes"].flatMap { Int64(String(describing: $0)) }
            ?? item.metadata["itemByteSize"].flatMap { Int64(String(describing: $0)) }

        return IPADownloadMetadata(
            url: url,
            displayVersion: item.metadata["bundleShortVersionString"] as? String,
            fileSizeBytes: size
        )
    }
}
