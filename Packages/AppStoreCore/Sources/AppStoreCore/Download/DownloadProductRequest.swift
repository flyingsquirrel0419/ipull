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
        /// FairPlay license blobs ipatool writes into the package.
        public let sinfs: [[String: Any]]

        public init(metadata: [String: Any], downloadURL: URL?, sinfs: [[String: Any]] = []) {
            self.metadata = metadata
            self.downloadURL = downloadURL
            self.sinfs = sinfs
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

        // The bag values are complete endpoints (…/r/redownload and
        // …/up/updateProduct); ipatool uses them verbatim plus ?guid=.
        let bag = try await bagProvider.bag(guid: guid)
        if let url = dispatchURL(bag.redownloadEndpoint, path: "/r/redownload", guid: guid) {
            if let item = try await sendSingle(
                http: http, url: url, session: session,
                appID: appID, guid: guid, versionKey: "appExtVrsId",
                externalVersionID: externalVersionID
            ) {
                return item
            }
        }

        if let url = dispatchURL(bag.updateEndpoint, path: "/up/updateProduct", guid: guid) {
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

    /// ipatool's newDownloadEndpoint: https, downloaddispatch.itunes.apple.com,
    /// the exact path, no query of its own.
    static func dispatchURL(_ endpoint: URL?, path: String, guid: String) -> URL? {
        guard let endpoint, endpoint.scheme == "https",
              endpoint.host == "downloaddispatch.itunes.apple.com",
              endpoint.path == path, endpoint.query == nil else { return nil }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "guid", value: guid)]
        return components?.url
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
        Log.info(.download, "downloadProduct \(url.host ?? "?")\(url.path) -> HTTP \(response.statusCode), \(response.data.count) bytes")

        // An empty 500 means "try the next endpoint" per observed behavior.
        if response.statusCode == 500 && response.data.isEmpty { return nil }
        guard response.statusCode == 200 else { return nil }

        guard let plist = try? PropertyListSerialization.propertyList(from: response.data, format: nil) as? [String: Any]
        else { return nil }

        return try interpret(plist: plist)
    }

    /// Interpret a downloadProduct response plist the way ipatool's
    /// Download does. Items live under "songList". Returns nil only for an
    /// empty or "no longer available" response, where ipatool falls back
    /// to the next endpoint; every other failure is an error.
    static func interpret(plist: [String: Any]) throws -> Item? {
        let failureType = (plist["failureType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let customerMessage = (plist["customerMessage"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let items = plist["songList"] as? [[String: Any]] ?? plist["items"] as? [[String: Any]] ?? []

        Log.info(.download, "downloadProduct result: failureType=\(failureType ?? "<none>") songs=\(items.count) message=\(customerMessage == nil ? "none" : "present")")
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

        if failureType == nil, items.isEmpty {
            let unavailable = customerMessage.map { $0.lowercased() }
                .map { $0 == "no longer available" || $0.hasSuffix(" no longer available") } ?? true
            if unavailable { return nil }
        }
        if let customerMessage, failureType != nil || items.isEmpty {
            throw AppStoreError.unknown(customerMessage)
        }
        if let failureType {
            throw AppStoreError.unknown("Apple download error \(failureType)")
        }

        let first = items[0]
        let metadata = first["metadata"] as? [String: Any] ?? [:]
        let downloadURL = (first["URL"] as? String).flatMap { URL(string: $0) }
        let sinfs = first["sinfs"] as? [[String: Any]] ?? []
        return Item(metadata: metadata, downloadURL: downloadURL, sinfs: sinfs)
    }
}
