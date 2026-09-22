import Foundation
import AppStoreCore

/// Disk layout:
///   Application Support/IPA/<appID>/<version>/<AppName>_<version>.ipa
public struct IPAStorage: Sendable {
    public let rootURL: URL

    public init(fileManager: FileManager = .default) throws {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        rootURL = appSupport.appendingPathComponent("IPA", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        // Exclude IPAs from iCloud backup — they're re-downloadable.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = rootURL
        try? mutableRoot.setResourceValues(values)
    }

    public func directory(forAppID appID: Int64, version: String) -> URL {
        rootURL
            .appendingPathComponent(String(appID), isDirectory: true)
            .appendingPathComponent(FileNaming.sanitize(version, maxLength: 40), isDirectory: true)
    }

    public func fileURL(appName: String, appID: Int64, version: String) -> URL {
        directory(forAppID: appID, version: version)
            .appendingPathComponent(FileNaming.ipaFileName(appName: appName, version: version))
    }

    public func relativePath(forAbsolute url: URL) -> String {
        url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
    }

    public func absoluteURL(forRelative path: String) -> URL {
        rootURL.appendingPathComponent(path)
    }

    public func existingFile(appID: Int64, version: String) -> URL? {
        let dir = directory(forAppID: appID, version: version)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }
        return contents.first { $0.pathExtension == "ipa" }
    }

    /// Total size of all stored IPAs, streamed (never loads files into RAM).
    public func totalStorageBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    public func freeDiskBytes() -> Int64? {
        let values = try? rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
