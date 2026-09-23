import Foundation

/// Facade composing all App Store services. The app layer talks to this.
public final class AppStoreClient: Sendable {
    public let auth: any AuthenticationServicing
    public let search: any SearchServicing
    public let versions: any VersionServicing
    public let purchase: any PurchaseServicing
    public let downloadMetadata: any DownloadMetadataServicing
    public let ownedApps: any OwnedAppsServicing

    public init(
        auth: any AuthenticationServicing,
        search: any SearchServicing,
        versions: any VersionServicing,
        purchase: any PurchaseServicing,
        downloadMetadata: any DownloadMetadataServicing,
        ownedApps: any OwnedAppsServicing
    ) {
        self.auth = auth
        self.search = search
        self.versions = versions
        self.purchase = purchase
        self.downloadMetadata = downloadMetadata
        self.ownedApps = ownedApps
    }

    /// Live wiring for the iOS app.
    public static func live(secrets: SecretStore) -> AppStoreClient {
        let http = URLSessionHTTPClient()
        let bag = BagService(http: http)
        let guidProvider: @Sendable () throws -> String = {
            try DeviceIdentity.currentGUID(secretStore: secrets)
        }
        let hardwareID = (try? DeviceIdentity.currentGUID(secretStore: secrets))
            .flatMap { Data($0.utf8) } ?? Data()
        let assets = SAPAssets(http: http)
        let signer = EmulatedSAPSigner(http: http, bagProvider: bag,
                                       assetProvider: assets, hardwareID: hardwareID)
        return AppStoreClient(
            auth: AuthenticationService(http: http, bagProvider: bag, signer: signer, secrets: secrets, guidProvider: guidProvider),
            search: SearchService(http: http),
            versions: VersionService(http: http, bagProvider: bag, guidProvider: guidProvider),
            purchase: PurchaseService(http: http, bagProvider: bag, guidProvider: guidProvider),
            downloadMetadata: DownloadMetadataService(http: http, bagProvider: bag, guidProvider: guidProvider),
            ownedApps: OwnedAppsService(http: http, signer: signer, guidProvider: guidProvider)
        )
    }
}
