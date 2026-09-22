import Foundation

/// An App Store catalog app.
public struct AppStoreApp: Sendable, Equatable, Identifiable, Codable {
    /// Numeric App Store identifier (trackId / adamId). Authoritative.
    public let id: Int64
    public let bundleID: String
    public let name: String
    public let developerName: String?
    public let iconURL: URL?
    public let storefront: String?
    public let currentVersion: String?
    public let price: Double?
    public let fileSizeBytes: Int64?

    public init(
        id: Int64,
        bundleID: String,
        name: String,
        developerName: String? = nil,
        iconURL: URL? = nil,
        storefront: String? = nil,
        currentVersion: String? = nil,
        price: Double? = nil,
        fileSizeBytes: Int64? = nil
    ) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.developerName = developerName
        self.iconURL = iconURL
        self.storefront = storefront
        self.currentVersion = currentVersion
        self.price = price
        self.fileSizeBytes = fileSizeBytes
    }
}

/// A downloadable version of an app.
public struct AppStoreVersion: Sendable, Equatable, Identifiable, Codable {
    /// Stable identity for SwiftUI lists.
    public var id: String { externalVersionID }
    /// Human-readable version, e.g. "446.0.0". May be unknown until resolved.
    public let displayVersion: String?
    /// Apple external version identifier used to pin downloads.
    public let externalVersionID: String
    public let releaseDate: Date?
    public let isLatest: Bool

    public init(
        displayVersion: String?,
        externalVersionID: String,
        releaseDate: Date? = nil,
        isLatest: Bool = false
    ) {
        self.displayVersion = displayVersion
        self.externalVersionID = externalVersionID
        self.releaseDate = releaseDate
        self.isLatest = isLatest
    }
}

/// Authenticated Apple Account session. Secrets (passwordToken) are stored
/// in the Keychain, never in SwiftData or logs.
public struct AppleAccountSession: Sendable, Equatable, Codable {
    public let email: String
    public let displayName: String
    public let directoryServicesID: String
    public let storefront: String
    public let pod: String?
    /// Sensitive. Redacted from all debug output.
    public let passwordToken: String

    public init(
        email: String,
        displayName: String,
        directoryServicesID: String,
        storefront: String,
        pod: String?,
        passwordToken: String
    ) {
        self.email = email
        self.displayName = displayName
        self.directoryServicesID = directoryServicesID
        self.storefront = storefront
        self.pod = pod
        self.passwordToken = passwordToken
    }

    /// Country code portion of the storefront, e.g. "kr".
    public var countryCode: String? {
        Storefront.countryCode(forStorefrontID: storefront)
    }
}

extension AppleAccountSession: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "AppleAccountSession(email: \(email), dsid: \(directoryServicesID), storefront: \(storefront), passwordToken: <redacted>)"
    }
    public var debugDescription: String { description }
}
