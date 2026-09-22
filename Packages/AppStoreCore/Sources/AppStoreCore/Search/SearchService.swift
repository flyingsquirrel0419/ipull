import Foundation

/// Unauthenticated iTunes Search/Lookup API client (public affiliate API).
public protocol SearchServicing: Sendable {
    func search(term: String, countryCode: String, limit: Int) async throws -> [AppStoreApp]
    func lookup(bundleID: String, countryCode: String) async throws -> AppStoreApp
    func lookup(appID: Int64, countryCode: String) async throws -> AppStoreApp
}

public final class SearchService: SearchServicing, @unchecked Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient) {
        self.http = http
    }

    public func search(term: String, countryCode: String, limit: Int = 25) async throws -> [AppStoreApp] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppStoreError.invalidInput }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "country", value: countryCode),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "media", value: "software"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200))),
        ]
        return try await perform(components.url!)
    }

    public func lookup(bundleID: String, countryCode: String) async throws -> AppStoreApp {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "country", value: countryCode),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "media", value: "software"),
        ]
        guard let app = try await perform(components.url!).first else {
            throw AppStoreError.appNotFound
        }
        return app
    }

    public func lookup(appID: Int64, countryCode: String) async throws -> AppStoreApp {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(appID)),
            URLQueryItem(name: "country", value: countryCode),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "media", value: "software"),
        ]
        guard let app = try await perform(components.url!).first else {
            throw AppStoreError.appNotFound
        }
        return app
    }

    private func perform(_ url: URL) async throws -> [AppStoreApp] {
        let request = HTTPRequest(url: url, headers: ["User-Agent": "iPull/1.0"])
        let response = try await http.send(request, body: nil)
        guard response.statusCode == 200 else {
            throw AppStoreError.unknown("Lookup failed with status \(response.statusCode)")
        }
        let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: response.data)
        return decoded.results.compactMap { $0.asAppStoreApp }
    }
}

// MARK: - iTunes API response mapping

struct ITunesSearchResponse: Decodable {
    let results: [ITunesAppResult]
}

struct ITunesAppResult: Decodable {
    let trackId: Int64
    let bundleId: String?
    let trackName: String?
    let artistName: String?
    let artworkUrl512: String?
    let artworkUrl100: String?
    let version: String?
    let price: Double?
    let fileSizeBytes: String?

    var asAppStoreApp: AppStoreApp? {
        guard let bundleId, let trackName else { return nil }
        return AppStoreApp(
            id: trackId,
            bundleID: bundleId,
            name: trackName,
            developerName: artistName,
            iconURL: (artworkUrl512 ?? artworkUrl100).flatMap { URL(string: $0) },
            currentVersion: version,
            price: price,
            fileSizeBytes: fileSizeBytes.flatMap { Int64($0) }
        )
    }
}
