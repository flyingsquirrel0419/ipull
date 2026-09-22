import Foundation

/// Fetches Apple's "bag" — runtime service configuration. Endpoints are
/// never hardcoded beyond the two fixed hosts; everything else comes from
/// the bag so Apple-side rotations keep working.
public struct Bag: Sendable, Equatable {
    public let authEndpoint: URL
    public let redownloadEndpoint: URL?
    public let updateEndpoint: URL?
    public let sapSetupEndpoint: URL?
    public let sapSetupCertEndpoint: URL?
    public let sapVersion: String?

    public init(authEndpoint: URL, redownloadEndpoint: URL? = nil, updateEndpoint: URL? = nil,
                sapSetupEndpoint: URL? = nil, sapSetupCertEndpoint: URL? = nil, sapVersion: String? = nil) {
        self.authEndpoint = authEndpoint
        self.redownloadEndpoint = redownloadEndpoint
        self.updateEndpoint = updateEndpoint
        self.sapSetupEndpoint = sapSetupEndpoint
        self.sapSetupCertEndpoint = sapSetupCertEndpoint
        self.sapVersion = sapVersion
    }
}

public protocol BagProviding: Sendable {
    func bag(guid: String) async throws -> Bag
}

/// Actor-isolated bag fetch + cache.
public actor BagService: BagProviding {
    private let http: HTTPClient
    private var cached: Bag?

    public init(http: HTTPClient) {
        self.http = http
    }

    public func bag(guid: String) async throws -> Bag {
        if let cached { return cached }

        var components = URLComponents(string: "https://init.itunes.apple.com/bag.xml")!
        components.queryItems = [URLQueryItem(name: "guid", value: guid)]
        let request = HTTPRequest(
            url: components.url!,
            headers: ["User-Agent": "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"]
        )

        let response = try await http.send(request, body: nil)
        guard response.statusCode == 200 else {
            throw AppStoreError.unknown("Bag request failed with status \(response.statusCode)")
        }

        let bag = try Self.parse(data: response.data)
        cached = bag
        return bag
    }

    nonisolated static func parse(data: Data) throws -> Bag {
        // The interesting keys live under "urlBag" when the request carries
        // the Configurator user agent; some responses place them at the top
        // level, and current bag.xml omits them entirely without specific
        // client headers. Check both levels, then fall back to the
        // documented default hosts — always validated below.
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw AppStoreError.unknown("Malformed bag response") }

        let urlBag = (root["urlBag"] as? [String: Any]) ?? root

        let authString = (urlBag["authenticateAccount"] as? String)
            ?? "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
        guard let authURL = URL(string: authString) else {
            throw AppStoreError.unknown("Malformed bag response")
        }
        try validate(authEndpoint: authURL)

        func optionalURL(_ key: String) -> URL? {
            (urlBag[key] as? String).flatMap { URL(string: $0) }
        }

        return Bag(
            authEndpoint: authURL,
            redownloadEndpoint: optionalURL("redownloadProduct"),
            updateEndpoint: optionalURL("updateProduct"),
            sapSetupEndpoint: optionalURL("sign-sap-setup")
                ?? URL(string: "https://play.itunes.apple.com/WebObjects/MZPlay.woa/wa/signSapSetup"),
            sapSetupCertEndpoint: optionalURL("sign-sap-setup-cert")
                ?? URL(string: "https://play.itunes.apple.com/WebObjects/MZPlay.woa/wa/signSapSetupCert"),
            sapVersion: (urlBag["sign-sap-version"] as? String) ?? "200"
        )
    }

    /// Auth endpoint must be https and on an Apple buy host.
    nonisolated static func validate(authEndpoint url: URL) throws {
        guard url.scheme == "https", let host = url.host?.lowercased() else {
            throw AppStoreError.unknown("Invalid authentication endpoint in bag")
        }
        guard host == "buy.itunes.apple.com" || host.hasSuffix("-buy.itunes.apple.com") else {
            throw AppStoreError.unknown("Unexpected authentication endpoint host")
        }
    }
}
