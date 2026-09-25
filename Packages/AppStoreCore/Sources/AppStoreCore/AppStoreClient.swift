import Foundation

/// Facade composing all App Store services. The app layer talks to this.
public final class AppStoreClient: Sendable {
    public let auth: any AuthenticationServicing
    public let search: any SearchServicing
    public let versions: any VersionServicing
    public let purchase: any PurchaseServicing
    public let downloadMetadata: any DownloadMetadataServicing

    public init(
        auth: any AuthenticationServicing,
        search: any SearchServicing,
        versions: any VersionServicing,
        purchase: any PurchaseServicing,
        downloadMetadata: any DownloadMetadataServicing
    ) {
        self.auth = auth
        self.search = search
        self.versions = versions
        self.purchase = purchase
        self.downloadMetadata = downloadMetadata
    }

    /// Live wiring for the iOS app.
    public static func live(secrets: SecretStore,
                            progress: (@Sendable (AuthenticationProgress) -> Void)? = nil) -> AppStoreClient {
        let http = URLSessionHTTPClient()
        let bag = BagService(http: http)
        let guidProvider: @Sendable () throws -> String = {
            try DeviceIdentity.currentGUID(secretStore: secrets)
        }
        let assets = SAPAssets(http: http) { assetProgress in
            switch assetProgress {
            case .downloading(let completed, let total):
                progress?(.downloadingAssets(completedBytes: completed, totalBytes: total))
            case .extracting:
                progress?(.extractingAssets)
            }
        }
        // Factory so AuthenticationService can mint a fresh signer when the
        // GUID rotates mid-login (the SAP hardware ID must match the new
        // GUID in the authenticate body).
        let signerFactory: @Sendable (Data) async throws -> any SAPSigning = { id in
            EmulatedSAPSigner(http: http, bagProvider: bag,
                              assetProvider: assets, hardwareID: id, progress: progress)
        }
        return AppStoreClient(
            auth: AuthenticationService(http: http, bagProvider: bag, signerFactory: signerFactory, secrets: secrets, progress: progress),
            search: SearchService(http: http),
            versions: VersionService(http: http, bagProvider: bag, guidProvider: guidProvider),
            purchase: PurchaseService(http: http, bagProvider: bag, guidProvider: guidProvider),
            downloadMetadata: DownloadMetadataService(http: http, bagProvider: bag, guidProvider: guidProvider)
        )
    }
}
