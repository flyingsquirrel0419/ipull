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

    public init(
        appName: String,
        version: String,
        bundleID: String,
        appID: Int64,
        fileSizeBytes: Int64,
        downloadedAt: Date = .now,
        relativeFilePath: String,
        sha256: String? = nil
    ) {
        self.appName = appName
        self.version = version
        self.bundleID = bundleID
        self.appID = appID
        self.fileSizeBytes = fileSizeBytes
        self.downloadedAt = downloadedAt
        self.relativeFilePath = relativeFilePath
        self.sha256 = sha256
    }
}

/// A recently viewed app for the Home screen.
@Model
public final class RecentApp {
    public var appID: Int64
    public var bundleID: String
    public var name: String
    public var developerName: String?
    public var viewedAt: Date

    public init(appID: Int64, bundleID: String, name: String, developerName: String?, viewedAt: Date = .now) {
        self.appID = appID
        self.bundleID = bundleID
        self.name = name
        self.developerName = developerName
        self.viewedAt = viewedAt
    }
}
