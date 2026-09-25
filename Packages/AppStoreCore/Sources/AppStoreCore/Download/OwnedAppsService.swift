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
    /// Apps the account has acquired, newest purchase first. `page` starts
    /// at 1; a `limit` of 0 returns every app.
    func ownedApps(session: AppleAccountSession, page: Int, limit: Int) async throws -> OwnedAppsPage
}

/// Purchase history over Apple's Purchase DAAP service, ported from
/// ipatool's appstore_owned_apps.go: for each of the ",34" and ",13"
/// storefront variants, an unsigned /login yields a session ID, a signed
/// /update yields the database revision, and a signed /databases/N/items
/// returns the DMAP item list. One SAP signer serves the whole listing and
/// is closed afterwards.
public final class OwnedAppsService: OwnedAppsServicing, @unchecked Sendable {
    static let baseURL = "https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase"
    static let appsMediaKind: UInt64 = 131_072
    static let arcadeMediaKind: UInt64 = 262_144
    static let macMediaKind: UInt64 = 67_108_864

    private let http: HTTPClient
    private let signerFactory: @Sendable (Data) async throws -> any SAPSigning
    private let guidProvider: @Sendable () throws -> String

    public init(http: HTTPClient,
                signerFactory: @escaping @Sendable (Data) async throws -> any SAPSigning,
                guidProvider: @escaping @Sendable () throws -> String) {
        self.http = http
        self.signerFactory = signerFactory
        self.guidProvider = guidProvider
    }

    public func ownedApps(session: AppleAccountSession, page: Int = 1, limit: Int = 0) async throws -> OwnedAppsPage {
        let guid = try guidProvider()
        let signer = try await signerFactory(DeviceIdentity.machineID(forGUID: guid))
        let fetched: [Owned]
        do {
            fetched = try await fetchAll(session: session, guid: guid, signer: signer)
        } catch {
            await (signer as? SAPSessionClosing)?.closeSession()
            throw error
        }
        await (signer as? SAPSessionClosing)?.closeSession()

        let sorted = Self.sortedByPurchaseDate(fetched)
        let apps = sorted.map(\.app)
        let pageNumber = max(page, 1)
        guard limit > 0 else { return OwnedAppsPage(apps: apps, totalCount: apps.count, page: pageNumber) }
        let start = (pageNumber - 1) * limit
        let slice = start < apps.count ? Array(apps[start..<min(start + limit, apps.count)]) : []
        return OwnedAppsPage(apps: slice, totalCount: apps.count, page: pageNumber)
    }

    // MARK: - Protocol steps

    struct Owned: Equatable {
        var app: AppStoreApp
        var purchaseDate: Date?
    }

    private func fetchAll(session: AppleAccountSession, guid: String, signer: any SAPSigning) async throws -> [Owned] {
        let storeFront = session.storefront.split(separator: ",", maxSplits: 1).first.map(String.init) ?? session.storefront
        var all: [Owned] = []
        for store in ["34", "13"] {
            all += try await fetch(session: session, storeFront: storeFront + "," + store, guid: guid, signer: signer)
        }
        return Self.merge(all)
    }

    private func fetch(session: AppleAccountSession, storeFront: String, guid: String,
                       signer: any SAPSigning) async throws -> [Owned] {
        let login = try await send("/login", session: session, storeFront: storeFront, guid: guid,
                                   contentType: nil, body: nil, signer: nil, label: "purchase history login")
        guard let sessionID = try DMAP.firstUInt(login, "mlid"), sessionID <= UInt64(UInt32.max) else {
            throw AppStoreError.unknown("Purchase history login did not return a session")
        }

        let query = "('com.apple.itunes.extended\\-media\\-kind:\(Self.appsMediaKind)',"
            + "'com.apple.itunes.extended\\-media\\-kind:\(Self.arcadeMediaKind)',"
            + "'com.apple.itunes.extended\\-media\\-kind:\(Self.macMediaKind)')"
        let updateBody = Data("session-id=\(sessionID)&revision-number=(null)&query=\(query)".utf8)
        let update = try await send("/update", session: session, storeFront: storeFront, guid: guid,
                                    contentType: "application/x-www-form-urlencoded", body: updateBody,
                                    signer: signer, label: "purchase history update")
        guard let revision = try DMAP.firstUInt(update, "musr"), revision <= UInt64(UInt32.max) else {
            throw AppStoreError.unknown("Purchase history update did not return a revision")
        }

        let itemsBody = Self.itemsBody(sessionID: UInt32(sessionID), revision: UInt32(revision), query: query, now: Date())
        let items = try await send("/databases/\(revision)/items", session: session, storeFront: storeFront, guid: guid,
                                   contentType: "application/x-dmap-tagged", body: itemsBody,
                                   signer: signer, label: "purchase history items")
        let parsed = try Self.parseItems(items)
        Log.info(.library, "purchase history \(storeFront.split(separator: ",").last ?? ""): \(parsed.count) apps")
        return parsed
    }

    private func send(_ path: String, session: AppleAccountSession, storeFront: String, guid: String,
                      contentType: String?, body: Data?, signer: (any SAPSigning)?, label: String) async throws -> Data {
        var headers = Self.headers(session: session, storeFront: storeFront, guid: guid, now: Date())
        if let contentType { headers["Content-Type"] = contentType }
        if let signer {
            headers["X-Apple-ActionSignature"] = try await signer.sign(body: body ?? Data())
        }
        let request = HTTPRequest(url: URL(string: Self.baseURL + path)!, method: "POST", headers: headers)
        let response = try await http.send(request, body: body)

        if response.statusCode == 401 || response.statusCode == 403 {
            Log.error(.library, "\(label) returned HTTP \(response.statusCode)")
            throw AppStoreError.sessionExpired
        }
        guard response.statusCode == 200 else {
            Log.error(.library, "\(label) returned HTTP \(response.statusCode)")
            throw AppStoreError.unknown("\(label) failed (HTTP \(response.statusCode))")
        }
        if let status = try DMAP.firstUInt(response.data, "mstt"), status != 200 {
            Log.error(.library, "\(label) returned DAAP status \(status)")
            if status == 401 || status == 403 { throw AppStoreError.sessionExpired }
            throw AppStoreError.unknown("\(label) failed (DAAP status \(status))")
        }
        return response.data
    }

    static func headers(session: AppleAccountSession, storeFront: String, guid: String, now: Date) -> [String: String] {
        let http = DateFormatter()
        http.locale = Locale(identifier: "en_US_POSIX")
        http.timeZone = TimeZone(identifier: "GMT")
        http.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let zone = TimeZone.current
        return [
            "Accept": "*/*",
            "Accept-Language": "en-us",
            "Client-Cloud-DAAP-Request-Reason": "5",
            "Client-Cloud-Purchase-Daap-Version": "1.1/Configurator-2.0",
            "Client-DAAP-Version": "3.12",
            "Date": http.string(from: now),
            "iCloud-DSID": session.directoryServicesID,
            "X-Apple-I-Client-Time": iso.string(from: now),
            "X-Apple-I-Locale": "en_US",
            "X-Apple-I-TimeZone": zone.identifier,
            "X-Apple-Store-Front": storeFront,
            "X-Apple-TZ": String(zone.secondsFromGMT(for: now) / 60),
            "X-Dsid": session.directoryServicesID,
            "X-Guid": guid,
            "X-Token": session.passwordToken,
        ]
    }

    static func itemsBody(sessionID: UInt32, revision: UInt32, query: String, now: Date) -> Data {
        var payload = Data()
        payload.append(DMAP.uint32("mstc", UInt32(truncatingIfNeeded: Int64(now.timeIntervalSince1970))))
        payload.append(DMAP.uint32("mlid", sessionID))
        payload.append(DMAP.uint8("mikd", 2))
        payload.append(DMAP.uint32("musr", revision))
        payload.append(DMAP.uint32("mder", 0))
        payload.append(DMAP.string("mque", query))
        payload.append(DMAP.tag("aetl"))
        return DMAP.tag("adsr", payload)
    }

    // MARK: - Parsing

    static func parseItems(_ data: Data) throws -> [Owned] {
        var owned: [Owned] = []
        try DMAP.walk(data) { name, payload in
            guard name == "mlit", let item = try parseItem(payload) else { return }
            owned.append(item)
        }
        return merge(owned)
    }

    private static func parseItem(_ data: Data) throws -> Owned? {
        var id: Int64 = 0
        var bundleID = ""
        var name = ""
        var fallbackName = ""
        var version: String?
        var purchaseDate: Date?
        try DMAP.walk(data) { tag, payload in
            switch tag {
            case "aeSI":
                guard payload.count == 4 || payload.count == 8, let value = DMAP.unsigned(payload),
                      value <= UInt64(Int64.max) else {
                    throw DMAP.ParseError(reason: "invalid owned app ID")
                }
                id = Int64(value)
            case "aeBI": bundleID = String(decoding: payload, as: UTF8.self)
            case "aeLN": name = String(decoding: payload, as: UTF8.self)
            case "minm": fallbackName = String(decoding: payload, as: UTF8.self)
            case "aePd": version = String(decoding: payload, as: UTF8.self)
            case "asdp":
                guard payload.count == 4, let seconds = DMAP.unsigned(payload) else {
                    throw DMAP.ParseError(reason: "invalid purchase date")
                }
                purchaseDate = Date(timeIntervalSince1970: TimeInterval(seconds))
            default:
                break
            }
        }
        guard id != 0 else { return nil }
        let app = AppStoreApp(id: id, bundleID: bundleID, name: name.isEmpty ? fallbackName : name,
                              currentVersion: version)
        return Owned(app: app, purchaseDate: purchaseDate)
    }

    /// One entry per app ID, keeping the latest purchase date.
    static func merge(_ apps: [Owned]) -> [Owned] {
        var merged: [Owned] = []
        var index: [Int64: Int] = [:]
        for entry in apps {
            if let existing = index[entry.app.id] {
                if let date = entry.purchaseDate, date > (merged[existing].purchaseDate ?? .distantPast) {
                    merged[existing].purchaseDate = date
                }
                continue
            }
            index[entry.app.id] = merged.count
            merged.append(entry)
        }
        return merged
    }

    /// Newest purchase first; undated entries last, otherwise stable.
    static func sortedByPurchaseDate(_ apps: [Owned]) -> [Owned] {
        apps.enumerated().sorted { lhs, rhs in
            switch (lhs.element.purchaseDate, rhs.element.purchaseDate) {
            case let (l?, r?): return l == r ? lhs.offset < rhs.offset : l > r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}
