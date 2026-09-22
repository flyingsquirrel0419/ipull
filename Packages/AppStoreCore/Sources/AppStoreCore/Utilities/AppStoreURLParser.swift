import Foundation

/// What the user gave us on the Home screen / Share Extension.
public enum AppLookupRequest: Sendable, Equatable {
    case appStoreURL(id: Int64, storefront: String?)
    case appID(Int64)
    case bundleID(String)
    case searchTerm(String)
}

/// Robust parser for App Store URLs, raw App IDs, bundle IDs and free text.
///
/// Rules:
/// - Numeric App ID from the `id<digits>` path segment is authoritative;
///   the slug is never trusted.
/// - Query strings are ignored.
/// - Storefront ("kr", "us") is extracted when present.
public enum AppStoreURLParser {

    /// Parse arbitrary user input into an `AppLookupRequest`.
    public static func parse(_ rawInput: String) -> Result<AppLookupRequest, AppStoreError> {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .failure(.invalidInput) }

        if let urlResult = parseURL(input) {
            return urlResult
        }

        if let appID = Int64(input), appID > 0, input.allSatisfy(\.isNumber) {
            return .success(.appID(appID))
        }

        if isPlausibleBundleID(input) {
            return .success(.bundleID(input))
        }

        // Free text: treat as a search term when it has letters.
        if input.rangeOfCharacter(from: .letters) != nil {
            return .success(.searchTerm(input))
        }

        return .failure(.invalidInput)
    }

    /// Extract a numeric App ID from an App Store URL, if the input is one.
    public static func parseURL(_ input: String) -> Result<AppLookupRequest, AppStoreError>? {
        guard let components = URLComponents(string: input),
              let host = components.host?.lowercased()
        else { return nil }

        // Accept apps.apple.com and itunes.apple.com links only.
        guard host == "apps.apple.com" || host == "itunes.apple.com" || host.hasSuffix(".apps.apple.com")
        else {
            if components.scheme != nil, host.contains("apple") {
                return .failure(.invalidAppStoreURL)
            }
            return nil // Not a URL we handle; fall through to other parsers.
        }

        let pathSegments = components.path.split(separator: "/").map(String.init)

        // Find the "id<digits>" segment — authoritative.
        var appID: Int64?
        for segment in pathSegments.reversed() {
            if segment.hasPrefix("id"), let value = Int64(segment.dropFirst(2)), value > 0 {
                appID = value
                break
            }
        }
        // Also support "?id=12345" style (legacy itunes links).
        if appID == nil,
           let queryID = components.queryItems?.first(where: { $0.name == "id" })?.value,
           let value = Int64(queryID), value > 0 {
            appID = value
        }

        guard let id = appID else { return .failure(.invalidAppStoreURL) }

        // Storefront: path like /kr/app/... → "kr". Must be 2 lowercase letters
        // and not "app".
        var storefront: String?
        if let first = pathSegments.first,
           first.count == 2,
           first.allSatisfy({ $0.isLowercase && $0.isLetter }),
           first != "app" {
            storefront = first
        }

        return .success(.appStoreURL(id: id, storefront: storefront))
    }

    /// Loose bundle-ID shape: reverse-DNS, at least two dot-separated labels,
    /// alphanumerics + hyphen per label.
    public static func isPlausibleBundleID(_ input: String) -> Bool {
        guard input.count <= 255, !input.contains(" ") else { return false }
        let labels = input.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return labels.allSatisfy { label in
            !label.isEmpty &&
            !label.hasPrefix("-") &&
            !label.hasSuffix("-") &&
            label.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    /// Build an App Store web URL for an app id (used for "Open in App Store").
    public static func appStoreWebURL(appID: Int64, storefront: String = "us") -> URL? {
        URL(string: "https://apps.apple.com/\(storefront)/app/id\(appID)")
    }
}
