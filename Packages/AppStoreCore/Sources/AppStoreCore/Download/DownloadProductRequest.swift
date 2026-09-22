import Foundation

/// Shared request/response handling for Apple's volumeStoreDownloadProduct
/// and its redownload/update fallbacks. Used by both the version-listing and
/// the download-metadata flows.
public enum DownloadProductRequest {

    /// Metadata is a property-list value (String/Number/Array/Dictionary
    /// only) produced by PropertyListSerialization — safe to move across
    /// domains, hence @unchecked Sendable.
    public struct Item: @unchecked Sendable {
        public let metadata: [String: Any]
        public let downloadURL: URL?

        public init(metadata: [String: Any], downloadURL: URL?) {
            self.metadata = metadata
            self.downloadURL = downloadURL
        }
    }

    /// Send a downloadProduct request through the documented fallback chain:
    /// volumeStoreDownloadProduct → bag redownloadProduct → bag updateProduct.
    public static func send(
        http: HTTPClient,
        bagProvider: BagProviding,
        session: AppleAccountSession,
        appID: Int64,
        guid: String,
        externalVersionID: String?
    ) async throws -> Item {
        let podPrefix = session.pod.map { "p\($0)-" } ?? ""
        let volumeStoreURL = URL(string:
            "https://\(podPrefix)buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=\(guid)"
        )!

        if let item = try await sendSingle(
            http: http, url: volumeStoreURL, session: session,
            appID: appID, guid: guid, versionKey: "externalVersionId",
            externalVersionID: externalVersionID
        ) {
            return item
        }

        let bag = try await bagProvider.bag(guid: guid)
        if let redownloadBase = bag.redownloadEndpoint,
           let url = URL(string: "\(redownloadBase.absoluteString)/r/redownload?guid=\(guid)") {
            if let item = try await sendSingle(
                http: http, url: url, session: session,
                appID: appID, guid: guid, versionKey: "appExtVrsId",
                externalVersionID: externalVersionID
            ) {
                return item
            }
        }

        if let updateBase = bag.updateEndpoint,
           let url = URL(string: "\(updateBase.absoluteString)/up/updateProduct?guid=\(guid)") {
            if let item = try await sendSingle(
                http: http, url: url, session: session,
                appID: appID, guid: guid, versionKey: "appExtVrsId",
                externalVersionID: externalVersionID
            ) {
                return item
            }
        }

        throw AppStoreError.downloadURLUnavailable
    }

    private static func sendSingle(
        http: HTTPClient,
        url: URL,
        session: AppleAccountSession,
        appID: Int64,
        guid: String,
        versionKey: String,
        externalVersionID: String?
    ) async throws -> Item? {
        var payload: [String: Any] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": appID,
            "serialNumber": "0",
        ]
        if let externalVersionID {
            payload[versionKey] = externalVersionID
        }

        let body = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

        let request = HTTPRequest(
            url: url,
            method: "POST",
            headers: [
                "Content-Type": "application/x-apple-plist",
                "iCloud-DSID": session.directoryServicesID,
                "X-Dsid": session.directoryServicesID,
            ]
        )
        let response = try await http.send(request, body: body)

        // An empty 500 means "try the next endpoint" per observed behavior.
        if response.statusCode == 500 && response.data.isEmpty { return nil }
        guard response.statusCode == 200 else { return nil }

        guard let plist = try? PropertyListSerialization.propertyList(from: response.data, format: nil) as? [String: Any]
        else { return nil }

        return try interpret(plist: plist)
    }

    /// Interpret a downloadProduct response plist, mapping Apple failure
    /// types onto typed errors. Returns nil for empty or message-only
    /// availability failures so the caller can try the next endpoint.
    static func interpret(plist: [String: Any]) throws -> Item? {
        let failureType = plist["failureType"] as? String
        let customerMessage = plist["customerMessage"] as? String

        switch failureType {
        case "2034", "2042", "1008", "5002":
            throw AppStoreError.sessionExpired
        case "9610":
            throw AppStoreError.appNotOwned
        default:
            break
        }

        if customerMessage == "Your password has changed." {
            throw AppStoreError.sessionExpired
        }

        let items = plist["items"] as? [[String: Any]] ?? []
        guard let first = items.first else {
            return nil
        }

        let metadata = first["metadata"] as? [String: Any] ?? [:]
        let downloadURLString = first["URL"] as? String
            ?? first["download-url"] as? String
        let downloadURL = downloadURLString.flatMap { URL(string: $0) }

        return Item(metadata: metadata, downloadURL: downloadURL)
    }
}
