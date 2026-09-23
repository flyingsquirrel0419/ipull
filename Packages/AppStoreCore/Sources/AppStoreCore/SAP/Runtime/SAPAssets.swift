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
    case missingFile(String)
}

public protocol SAPAssetProviding: Sendable {
    func load() async throws -> SAPAssetBundle
}

/// Loads SAP assets from cache, or downloads them from Apple's update
/// package and extracts them from its bzip2-compressed CPIO Scripts member.
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

    // MARK: - Download + extraction

    private func download() async throws -> SAPAssetBundle {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipull-sap-\(UUID().uuidString).pkg")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Retry with resume: swcdn supports Range. A lost connection
        // (URLError -1005, common on 1.2 GB downloads) picks up where it left off.
        let partialURL = tempURL
        var lastError: Error?
        for attempt in 1...3 {
            var request = HTTPRequest(url: Self.updateURL, headers: ["User-Agent": "iPull/1.0"])
            if let existing = try? FileManager.default.attributesOfItem(atPath: partialURL.path),
               let size = existing[.size] as? Int64, size > 0 {
                request.headers["Range"] = "bytes=\(size)-"
                Log.info(.auth, "resuming SAP asset download from \(size / 1_048_576) MB (attempt \(attempt))")
            }
            // Each attempt streams into its own scratch file; on success we
            // append it onto the shared partial so a retry resumes correctly.
            let attemptURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ipull-sap-attempt-\(UUID().uuidString).pkg")
            defer { try? FileManager.default.removeItem(at: attemptURL) }
            do {
                try await performDownload(request: request, to: attemptURL)
                if request.headers["Range"] != nil,
                   FileManager.default.fileExists(atPath: partialURL.path),
                   let existing = try? Data(contentsOf: partialURL, options: .mappedIfSafe),
                   let fresh = try? Data(contentsOf: attemptURL) {
                    var combined = existing
                    combined.append(fresh)
                    try combined.write(to: partialURL, options: .atomic)
                } else if !FileManager.default.fileExists(atPath: partialURL.path) {
                    try FileManager.default.moveItem(at: attemptURL, to: partialURL)
                }
                lastError = nil
                break
            } catch {
                lastError = error
                Log.error(.auth, "SAP asset download attempt \(attempt) failed: \(String(describing: type(of: error)))")
            }
        }
        if let lastError { throw lastError }
        let package = try Data(contentsOf: partialURL, options: .mappedIfSafe)

        let xar = try XARReader(data: package)
        // The pinned package keeps the files in the "Scripts" member, which is a
        // bzip2-compressed CPIO stream starting at byte 0 (verified against the
        // real package during development — see docs/research).
        guard let scriptsEntry = xar.entry(named: "Scripts"),
              let scriptsRaw = xar.bytes(of: scriptsEntry, in: package)
        else {
            throw SAPAssetsError.missingFile("Scripts")
        }

        // Stream the bzip2 decompression to disk — the ~3.6 GB result
        // cannot live in device memory.
        let scriptsTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipull-sap-scripts-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: scriptsTempURL) }
        try scriptsRaw.write(to: scriptsTempURL, options: .atomic)
        let cpioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipull-sap-cpio-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: cpioURL) }
        try Bzip2.decompressToFile(source: scriptsTempURL, destination: cpioURL)
        let cpioData = try Data(contentsOf: cpioURL, options: .mappedIfSafe)
        let entries = try CPIOReader.entries(in: cpioData)

        var found: [String: Data] = [:]
        for spec in Self.requiredFiles {
            guard let entry = entries.first(where: { $0.name == spec.path }) else {
                throw SAPAssetsError.missingFile(spec.name)
            }
            guard entry.body.count == spec.size else {
                throw SAPAssetsError.digestMismatch(spec.name)
            }
            found[spec.name] = entry.body
        }

        let bundle = SAPAssetBundle(
            commerceKit: found["CommerceKit"]!,
            commerceCore: found["CommerceCore"]!,
            coreFP: found["CoreFP"]!,
            coreFPICXS: found["CoreFP.icxs"]!
        )
        try Self.verify(bundle)
        return bundle
    }

    /// One download attempt: stream to disk when supported, else buffered.
    /// 206 (partial) is a valid resume response alongside 200.
    private func performDownload(request: HTTPRequest, to tempURL: URL) async throws {
        if let streaming = http as? StreamingHTTPClient {
            let response = try await streaming.download(request, to: tempURL) { written, total in
                let writtenMB = written / 1_048_576
                if let total {
                    Log.info(.auth, "SAP assets: \(writtenMB) MB / \(total / 1_048_576) MB")
                } else {
                    Log.info(.auth, "SAP assets: \(writtenMB) MB")
                }
            }
            guard response.statusCode == 200 || response.statusCode == 206 else {
                throw SAPAssetsError.downloadFailed("HTTP \(response.statusCode)")
            }
        } else {
            let response = try await http.send(request, body: nil)
            guard response.statusCode == 200 || response.statusCode == 206 else {
                throw SAPAssetsError.downloadFailed("HTTP \(response.statusCode)")
            }
            if FileManager.default.fileExists(atPath: tempURL.path),
               let existing = try? Data(contentsOf: tempURL) {
                var combined = existing
                combined.append(response.data)
                try combined.write(to: tempURL, options: .atomic)
            } else {
                try response.data.write(to: tempURL, options: .atomic)
            }
        }
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
