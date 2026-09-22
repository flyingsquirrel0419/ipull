import Foundation

public struct OwnedAppsPage: Sendable, Equatable {
    public let apps: [AppStoreApp]
    public let totalCount: Int
    public let page: Int

    public init(apps: [AppStoreApp], totalCount: Int, page: Int) {
        self.apps = apps
        self.totalCount = totalCount
        self.page = page
    }
}

public protocol OwnedAppsServicing: Sendable {
    /// List apps the account has previously acquired (purchased/downloaded).
    /// Requires SAP-signed requests; failure degrades gracefully in the UI
    /// (feature-flagged off with an explanatory empty state).
    func ownedApps(session: AppleAccountSession, page: Int, limit: Int) async throws -> OwnedAppsPage
}

/// Implements the purchase-DAAP owned-apps listing (media kinds per
/// documented behavior: 131072 iOS software).
public final class OwnedAppsService: OwnedAppsServicing, @unchecked Sendable {
    private let http: HTTPClient
    private let signer: SAPSigning
    private let guidProvider: @Sendable () throws -> String

    public init(http: HTTPClient, signer: SAPSigning, guidProvider: @escaping @Sendable () throws -> String) {
        self.http = http
        self.signer = signer
        self.guidProvider = guidProvider
    }

    public func ownedApps(session: AppleAccountSession, page: Int = 0, limit: Int = 50) async throws -> OwnedAppsPage {
        let guid = try guidProvider()
        let url = URL(string: "https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase")!

        let payload: [String: Any] = [
            "guid": guid,
            "mediaKinds": [131072],
            "page": page,
            "limit": min(max(limit, 1), 100),
        ]
        let body = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        let signature = try await signer.sign(body: body)

        let request = HTTPRequest(
            url: url,
            method: "POST",
            headers: [
                "Content-Type": "application/x-apple-plist",
                "iCloud-DSID": session.directoryServicesID,
                "X-Dsid": session.directoryServicesID,
                "X-Apple-Store-Front": session.storefront,
                "X-Token": session.passwordToken,
                "X-Apple-ActionSignature": signature,
            ]
        )
        let response = try await http.send(request, body: body)

        guard response.statusCode == 200,
              let plist = try? PropertyListSerialization.propertyList(from: response.data, format: nil) as? [String: Any]
        else {
            throw AppStoreError.unknown("Owned apps request failed (status \(response.statusCode))")
        }

        let failureType = plist["failureType"] as? String
        if failureType == "2034" || failureType == "2042" {
            throw AppStoreError.sessionExpired
        }

        let rawItems = plist["items"] as? [[String: Any]] ?? []
        let apps: [AppStoreApp] = rawItems.compactMap { item -> AppStoreApp? in
            let rawID = item["itemId"] ?? item["adamId"]
            guard let rawID, let adamID = Int64(String(describing: rawID)),
                  let bundleID = (item["softwareVersionBundleId"] as? String) ?? (item["bundleId"] as? String),
                  let name = (item["itemName"] as? String) ?? (item["name"] as? String)
            else { return nil }
            return AppStoreApp(
                id: adamID,
                bundleID: bundleID,
                name: name,
                developerName: item["artistName"] as? String
            )
        }

        let rawTotal = plist["totalCount"] ?? plist["total-count"]
        let total = rawTotal.flatMap { Int(String(describing: $0)) } ?? apps.count
        return OwnedAppsPage(apps: apps, totalCount: total, page: page)
    }
}
