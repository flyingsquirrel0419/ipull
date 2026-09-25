import Foundation
import SwiftData

/// A downloaded IPA tracked in the on-device Library.
@Model
public final class LibraryItem {
    public var appName: String
    public var version: String
    public var bundleID: String
    public var appID: Int64
    public var fileSizeBytes: Int64
    public var downloadedAt: Date
    /// Path relative to the IPA storage root (re-resolved on each launch,
    /// since the app container path can change across updates).
    public var relativeFilePath: String
    public var sha256: String?
    /// Optional so existing stores migrate without a custom migration plan.
    public var iconURLString: String?

    public init(
        appName: String,
        version: String,
        bundleID: String,
        appID: Int64,
        fileSizeBytes: Int64,
        downloadedAt: Date = .now,
        relativeFilePath: String,
        sha256: String? = nil,
        iconURL: URL? = nil
    ) {
        self.appName = appName
        self.version = version
        self.bundleID = bundleID
        self.appID = appID
        self.fileSizeBytes = fileSizeBytes
        self.downloadedAt = downloadedAt
        self.relativeFilePath = relativeFilePath
        self.sha256 = sha256
        self.iconURLString = iconURL?.absoluteString
    }

    public var iconURL: URL? { iconURLString.flatMap(URL.init(string:)) }
}

/// A recently viewed app for the Home screen.
@Model
public final class RecentApp {
    public var appID: Int64
    public var bundleID: String
    public var name: String
    public var developerName: String?
    public var viewedAt: Date
    /// Optional so existing stores migrate without a custom migration plan.
    public var iconURLString: String?

    public init(appID: Int64, bundleID: String, name: String, developerName: String?,
                iconURL: URL? = nil, viewedAt: Date = .now) {
        self.appID = appID
        self.bundleID = bundleID
        self.name = name
        self.developerName = developerName
        self.iconURLString = iconURL?.absoluteString
        self.viewedAt = viewedAt
    }

    public var iconURL: URL? { iconURLString.flatMap(URL.init(string:)) }
}
