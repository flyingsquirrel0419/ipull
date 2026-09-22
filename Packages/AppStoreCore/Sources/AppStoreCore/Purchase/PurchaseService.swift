import Foundation

public protocol PurchaseServicing: Sendable {
    /// Acquire a license for a FREE app on the signed-in account.
    /// Paid apps are refused — iPull never attempts paid acquisition.
    func acquireLicense(app: AppStoreApp, session: AppleAccountSession) async throws
}

public final class PurchaseService: PurchaseServicing, @unchecked Sendable {
    private let http: HTTPClient
    private let bagProvider: BagProviding
    private let guidProvider: @Sendable () throws -> String

    public init(http: HTTPClient, bagProvider: BagProviding, guidProvider: @escaping @Sendable () throws -> String) {
        self.http = http
        self.bagProvider = bagProvider
        self.guidProvider = guidProvider
    }

    public func acquireLicense(app: AppStoreApp, session: AppleAccountSession) async throws {
        if let price = app.price, price > 0 {
            throw AppStoreError.paidAppNotSupported
        }
        let guid = try guidProvider()

        do {
            try await purchase(app: app, session: session, guid: guid, pricingParameter: "STDQ")
        } catch AppStoreError.purchaseFailed {
            // Arcade fallback per documented behavior.
            try await purchase(app: app, session: session, guid: guid, pricingParameter: "GAME")
        }
    }

    private func purchase(app: AppStoreApp, session: AppleAccountSession, guid: String, pricingParameter: String) async throws {
        let podPrefix = session.pod.map { "p\($0)-" } ?? ""
        let url = URL(string:
            "https://\(podPrefix)buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct"
        )!

        let payload: [String: Any] = [
            "appExtVrsId": "0",
            "hasAskedToFulfillPreorder": "true",
            "buyWithoutAuthorization": "true",
            "hasDoneAgeCheck": "true",
            "guid": guid,
            "needDiv": "0",
            "origPage": "Software-\(app.id)",
            "origPageLocation": "Buy",
            "price": "0",
            "pricingParameters": pricingParameter,
            "productType": "C",
            "salableAdamId": app.id,
        ]
        let body = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

        let request = HTTPRequest(
            url: url,
            method: "POST",
            headers: [
                "Content-Type": "application/x-apple-plist",
                "iCloud-DSID": session.directoryServicesID,
                "X-Dsid": session.directoryServicesID,
                "X-Apple-Store-Front": session.storefront,
                "X-Token": session.passwordToken,
            ]
        )
        let response = try await http.send(request, body: body)

        guard let plist = try? PropertyListSerialization.propertyList(from: response.data, format: nil) as? [String: Any] else {
            if response.statusCode == 500 { return } // documented: 500 == license already exists
            throw AppStoreError.purchaseFailed
        }

        let failureType = plist["failureType"] as? String
        let customerMessage = plist["customerMessage"] as? String

        if failureType == "5002" { return } // license already exists — fine
        if failureType == "2034" || failureType == "2042" || failureType == "1008"
            || customerMessage == "Your password has changed." {
            throw AppStoreError.sessionExpired
        }
        if customerMessage == "Subscription Required" {
            throw AppStoreError.purchaseRequired
        }
        if failureType != nil {
            throw AppStoreError.purchaseFailed
        }

        let jingle = plist["jingleDocType"] as? String
        let status = plist["status"] as? Int
        guard jingle == "purchaseSuccess", status == 0 else {
            throw AppStoreError.purchaseFailed
        }
    }
}
