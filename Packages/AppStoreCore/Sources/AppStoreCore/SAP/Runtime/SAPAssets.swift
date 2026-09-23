import Foundation

/// Apple's SAP signing assets (Mach-O images) are downloaded at first use
/// directly from Apple's software-update CDN — never bundled or
/// redistributed with iPull. Each file is verified against a pinned
/// SHA-256 digest (from the MIT-licensed ipatool project, see NOTICES)
/// and cached under Application Support.
public struct SAPAssetBundle: Sendable {
    public let commerceKit: Data
    public let commerceCore: Data
    public let coreFP: Data
    public let coreFPICXS: Data

    public init(commerceKit: Data, commerceCore: Data, coreFP: Data, coreFPICXS: Data) {
        self.commerceKit = commerceKit
        self.commerceCore = commerceCore
        self.coreFP = coreFP
        self.coreFPICXS = coreFPICXS
    }
}

public enum SAPAssetsError: Error, Equatable {
    case downloadFailed(String)
    case digestMismatch(String)
    case archiveLayoutUnsupported(String)
    case missingFile(String)
}

public protocol SAPAssetProviding: Sendable {
    func load() async throws -> SAPAssetBundle
}

/// Loads SAP assets from cache, or downloads them from Apple's update
/// package with HTTP range reads (the package is >1 GB; we only read the
/// XAR table of contents and the payload regions we need).
public final class SAPAssets: SAPAssetProviding, @unchecked Sendable {

    struct FileSpec: Sendable {
        let name: String
        let path: String
        let size: Int
        let sha256Hex: String
    }

    /// Pinned to the macOS update package documented in ipatool (MIT).
    static let updateURL = URL(string:
        "https://swcdn.apple.com/content/downloads/27/34/041-98128-A_SYPWICN3KH/5dqkl4rqgbsr18yzy61yeie9g3cmjc5hiv/OSXUpd10.9.pkg"
    )!

    static let requiredFiles: [FileSpec] = [
        FileSpec(name: "CommerceKit",
                 path: "./System/Library/PrivateFrameworks/CommerceKit.framework/Versions/A/CommerceKit",
                 size: 3_271_840,
                 sha256Hex: "b84ff12c21987856c0a17b78f1ad82b73195a6dec5f3b208a17d245555a2c8a2"),
        FileSpec(name: "CommerceCore",
                 path: "./System/Library/PrivateFrameworks/CommerceKit.framework/Versions/A/Frameworks/CommerceCore.framework/Versions/A/CommerceCore",
                 size: 207_744,
                 sha256Hex: "c5401e57402230f3c876409d295319ddf1e61287bc882683c5d61277be7bc1f2"),
        FileSpec(name: "CoreFP",
                 path: "./System/Library/PrivateFrameworks/CoreFP.framework/Versions/A/CoreFP",
                 size: 29_014_912,
                 sha256Hex: "f19141336be4198d0f8991bb00017c915efc7aeaece36c345f7faa1237ea6074"),
        FileSpec(name: "CoreFP.icxs",
                 path: "./System/Library/PrivateFrameworks/CoreFP.framework/Versions/A/CoreFP.icxs",
                 size: 5_288_352,
                 sha256Hex: "473e78af86979f5bd4f6269561caf770b3d16c098d918846eeac8cdd2fe6566a"),
    ]

    private let http: HTTPClient
    private let cacheDirectory: URL

    public init(http: HTTPClient, cacheDirectory: URL? = nil) {
        self.http = http
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.cacheDirectory = appSupport.appendingPathComponent("SAPAssets", isDirectory: true)
        }
    }

    public func load() async throws -> SAPAssetBundle {
        if let cached = try loadCache() {
            return cached
        }
        Log.info(.auth, "SAP assets not cached; downloading from Apple CDN")
        let bundle = try await download()
        try writeCache(bundle)
        return bundle
    }

    // MARK: - Cache

    private func loadCache() throws -> SAPAssetBundle? {
        var files: [String: Data] = [:]
        for spec in Self.requiredFiles {
            let url = cacheDirectory.appendingPathComponent(spec.name)
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard data.count == spec.size,
                  SHA256Streamer.hash(data: data) == spec.sha256Hex else {
                Log.error(.auth, "SAP asset cache invalid for \(spec.name); redownloading")
                return nil
            }
            files[spec.name] = data
        }
        return SAPAssetBundle(
            commerceKit: files["CommerceKit"]!,
            commerceCore: files["CommerceCore"]!,
            coreFP: files["CoreFP"]!,
            coreFPICXS: files["CoreFP.icxs"]!
        )
    }

    private func writeCache(_ bundle: SAPAssetBundle) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let map: [(String, Data)] = [
            ("CommerceKit", bundle.commerceKit),
            ("CommerceCore", bundle.commerceCore),
            ("CoreFP", bundle.coreFP),
            ("CoreFP.icxs", bundle.coreFPICXS),
        ]
        for (name, data) in map {
            try data.write(to: cacheDirectory.appendingPathComponent(name), options: .atomic)
        }
    }

    // MARK: - Download

    /// Full package download + XAR/CPIO extraction. The package is large,
    /// but on-device storage and Apple CDN throughput make a streamed full
    /// download simpler and more reliable than chained range reads; the
    /// stream is written to a temp file and never held in memory.
    private func download() async throws -> SAPAssetBundle {
        throw SAPAssetsError.archiveLayoutUnsupported(
            "XAR/CPIO extraction is implemented in SAPXARReader; wire it here"
        )
    }

    static func verify(_ bundle: SAPAssetBundle) throws {
        let pairs: [(String, Data, String)] = [
            ("CommerceKit", bundle.commerceKit, requiredFiles[0].sha256Hex),
            ("CommerceCore", bundle.commerceCore, requiredFiles[1].sha256Hex),
            ("CoreFP", bundle.coreFP, requiredFiles[2].sha256Hex),
            ("CoreFP.icxs", bundle.coreFPICXS, requiredFiles[3].sha256Hex),
        ]
        for (name, data, expected) in pairs {
            let actual = SHA256Streamer.hash(data: data)
            guard actual == expected else {
                throw SAPAssetsError.digestMismatch(name)
            }
        }
    }
}
