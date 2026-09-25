import Foundation
import CBzip2

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

public enum SAPAssetProgress: Sendable, Equatable {
    case downloading(completedBytes: Int64, totalBytes: Int64)
    case extracting
}

/// Combines callbacks from simultaneous range requests. URLSession invokes
/// progress on delegate queues, so updates must be synchronized.
final class SAPDownloadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: [Int64]
    private let total: Int64
    private let report: @Sendable (SAPAssetProgress) -> Void

    init(parts: Int, total: Int64, report: @escaping @Sendable (SAPAssetProgress) -> Void) {
        completed = Array(repeating: 0, count: parts)
        self.total = total
        self.report = report
    }

    func update(part: Int, bytes: Int64) {
        lock.lock()
        completed[part] = max(0, bytes)
        let sum = min(total, completed.reduce(0, +))
        lock.unlock()
        report(.downloading(completedBytes: sum, totalBytes: total))
    }
}

/// Loads SAP assets from cache, or downloads them from Apple's update
/// package and extracts them from its bzip2-compressed CPIO Scripts member.
/// Assets are verified against pinned SHA-256 digests and cached under
/// Application Support — downloaded once, reused forever.
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
    private let progress: (@Sendable (SAPAssetProgress) -> Void)?

    public init(http: HTTPClient, cacheDirectory: URL? = nil,
                progress: (@Sendable (SAPAssetProgress) -> Void)? = nil) {
        self.http = http
        self.progress = progress
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

    // MARK: - Ranged extraction

    /// Absolute byte offset in the update package where the bzip2 stream
    /// containing the four required frameworks begins (a bzip2 BLOCK magic
    /// boundary, so the stream is decodable after prepending "BZh9").
    /// Determined empirically against Apple's swcdn; matches ipatool's
    /// payloadBZOffset (payload-relative 0x352F40D5 = heap 4287 + payload
    /// offset 4175029 + 892289237).
    static let assetStreamStart: Int64 = 896_468_553

    /// Compressed bytes past assetStreamStart that contain all four
    /// required files. Measured: CoreFP.icxs ends well within 32 MB
    /// (decompressed ~65 MB); 40 MB adds a safety margin while staying
    /// ~30x smaller than the full 1,217 MB package.
    static let assetStreamLength: Int64 = 40 * 1_048_576

    /// Bytes of decompressed CPIO to skip before the first full entry
    /// (ipatool's payloadCPIO: tail of a partial entry preceding the
    /// CommerceKit block).
    static let cpioSkipBytes = 932

    /// Download only the package region that holds the four assets and
    /// stream-decompress it, instead of pulling the full 1,217 MB package.
    /// First sign-in drops from ~1.2 GB to ~40 MB on the user's data plan.
    private func download() async throws -> SAPAssetBundle {
        guard let streaming = http as? StreamingHTTPClient else {
            throw SAPAssetsError.downloadFailed("ranged download requires a streaming HTTP client")
        }
        let start = Self.assetStreamStart
        let end = start + Self.assetStreamLength - 1
        let chunkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipull-sap-assets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: chunkURL) }

        var request = HTTPRequest(url: Self.updateURL, headers: ["User-Agent": "iPull/1.0"])
        request.headers["Range"] = "bytes=\(start)-\(end)"
        Log.info(.auth, "SAP assets: ranged download, \(Self.assetStreamLength / 1_048_576) MB (of 1,217 MB package)")
        let progress = self.progress
        let response = try await streaming.download(request, to: chunkURL) { written, total in
            progress?(.downloading(completedBytes: written, totalBytes: total ?? Self.assetStreamLength))
        }
        guard response.statusCode == 206 else {
            throw SAPAssetsError.downloadFailed("range request answered HTTP \(response.statusCode)")
        }

        progress?(.extracting)
        return try extractFromRangedStream(fileURL: chunkURL)
    }

    /// Decompress the ranged bzip2 stream (block-boundary start, so the
    /// "BZh9" stream magic is prepended) and pull the four wanted CPIO
    /// entries. Stops feeding the decompressor once all four are extracted
    /// — the trailing megabytes of the window are never decoded.
    func extractFromRangedStream(fileURL: URL) throws -> SAPAssetBundle {
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }

        guard let stream = cbzip2_stream_init() else { throw SAPAssetsError.downloadFailed("bzip2 init failed") }
        defer { cbzip2_stream_end(stream) }

        let extractor = CPIOSelectiveExtractor(wanted: Set(Self.requiredFiles.map(\.path)))
        var remainingSkip = Self.cpioSkipBytes
        let inChunkSize = 4 * 1_048_576
        let outChunkSize = 16 * 1_048_576

        // First chunk gets the bzip2 stream magic prepended: the window
        // starts at a block boundary past the original "BZh9" bytes.
        var first = true
        while !extractor.allFound {
            guard var chunk = try input.read(upToCount: inChunkSize), !chunk.isEmpty else { break }
            if first {
                chunk.insert(contentsOf: Data("BZh9".utf8), at: 0)
                first = false
            }
            var offset = 0
            while offset < chunk.count {
                var consumed = 0
                var outBuffer = Data(count: outChunkSize)
                let slice = chunk.subdata(in: offset..<chunk.count)
                let produced: Int = slice.withUnsafeBytes { inPtr in
                    outBuffer.withUnsafeMutableBytes { outPtr in
                        let r = cbzip2_stream_decompress(
                            stream,
                            inPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), slice.count,
                            &consumed,
                            outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), outChunkSize
                        )
                        return r < 0 ? -1 : Int(r)
                    }
                }
                guard produced >= 0 else { throw SAPAssetsError.downloadFailed("bzip2 stream corrupt") }
                offset += consumed
                if produced > 0 {
                    var piece = outBuffer.prefix(produced)
                    if remainingSkip > 0 {
                        piece = piece.dropFirst(min(remainingSkip, piece.count))
                        remainingSkip -= min(remainingSkip, piece.count)
                    }
                    if !piece.isEmpty { try extractor.consume(Data(piece)) }
                }
                if consumed == 0 && produced == 0 { break }
            }
        }

        var found: [String: Data] = [:]
        for spec in Self.requiredFiles {
            guard let body = extractor.files[spec.path], body.count == spec.size else {
                throw SAPAssetsError.missingFile(spec.name)
            }
            found[spec.name] = body
        }

        Log.info(.auth, "SAP assets extracted from ranged stream")
        let bundle = SAPAssetBundle(
            commerceKit: found["CommerceKit"]!,
            commerceCore: found["CommerceCore"]!,
            coreFP: found["CoreFP"]!,
            coreFPICXS: found["CoreFP.icxs"]!
        )
        try Self.verify(bundle)
        return bundle
    }

    /// Download small ranges so a stalled request can be retried without
    /// discarding hundreds of megabytes of already received data.
    func performParallelDownload(request base: HTTPRequest, to destination: URL, totalSize: Int64,
                                 rangeSize: Int64 = 16 * 1_048_576) async throws {
        let parts = 2
        precondition(rangeSize > 0 && totalSize >= 2)
        let chunkSize = totalSize / Int64(parts)
        let combinedProgress = progress.map { SAPDownloadProgress(parts: parts, total: totalSize, report: $0) }
        combinedProgress?.update(part: 0, bytes: 0)
        var partURLs: [URL] = []
        defer { for u in partURLs { try? FileManager.default.removeItem(at: u) } }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<parts {
                let start = Int64(index) * chunkSize
                let end = (index == parts - 1) ? totalSize - 1 : start + chunkSize - 1
                let partURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ipull-sap-part-\(index)-\(UUID().uuidString)")
                partURLs.append(partURL)

                group.addTask { [http] in
                    guard let streaming = http as? StreamingHTTPClient else {
                        throw SAPAssetsError.downloadFailed("range request required")
                    }
                    guard FileManager.default.createFile(atPath: partURL.path, contents: nil) else {
                        throw SAPAssetsError.downloadFailed("could not create part file")
                    }
                    let output = try FileHandle(forWritingTo: partURL)
                    defer { try? output.close() }
                    let rangeURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ipull-sap-range-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: rangeURL) }

                    var offset = start
                    while offset <= end {
                        try Task.checkCancellation()
                        let rangeEnd = min(end, offset + rangeSize - 1)
                        let completed = offset - start
                        var lastError: Error?
                        for attempt in 1...4 {
                            var rangeRequest = HTTPRequest(url: base.url, headers: base.headers)
                            rangeRequest.headers["Range"] = "bytes=\(offset)-\(rangeEnd)"
                            do {
                                let response = try await streaming.download(rangeRequest, to: rangeURL) { written, _ in
                                    combinedProgress?.update(part: index, bytes: completed + written)
                                }
                                let expectedRange = "bytes \(offset)-\(rangeEnd)/\(totalSize)"
                                let length = rangeEnd - offset + 1
                                let actualLength = (try FileManager.default.attributesOfItem(atPath: rangeURL.path)[.size] as? NSNumber)?.int64Value
                                guard response.statusCode == 206,
                                      response.header("Content-Range") == expectedRange,
                                      actualLength == length else {
                                    throw SAPAssetsError.downloadFailed("invalid range response")
                                }
                                let input = try FileHandle(forReadingFrom: rangeURL)
                                defer { try? input.close() }
                                while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                                    try output.write(contentsOf: data)
                                }
                                try FileManager.default.removeItem(at: rangeURL)
                                combinedProgress?.update(part: index, bytes: completed + length)
                                lastError = nil
                                break
                            } catch {
                                combinedProgress?.update(part: index, bytes: completed)
                                if Task.isCancelled { throw error }
                                lastError = error
                                Log.error(.auth, "part \(index) range attempt \(attempt) failed: \(String(describing: type(of: error)))")
                            }
                        }
                        if let lastError { throw lastError }
                        offset = rangeEnd + 1
                    }
                }
            }
            try await group.waitForAll()
        }

        // Concatenate parts in order.
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        for url in partURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try output.write(contentsOf: data)
        }
    }

    /// XAR Payload → bzip2 CPIO → extract only the four needed assets.
    func extractFrom(packageURL: URL) throws -> SAPAssetBundle {
        let input = try FileHandle(forReadingFrom: packageURL)
        defer { try? input.close() }
        let prefix = try input.read(upToCount: 64 * 1024) ?? Data()
        let xar = try XARReader(data: prefix)
        guard let payload = xar.entry(named: "Payload") else {
            throw SAPAssetsError.missingFile("Payload")
        }
        let packageSize = (try FileManager.default.attributesOfItem(atPath: packageURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard xar.heapBase + payload.offset + payload.length <= packageSize else {
            throw SAPAssetsError.downloadFailed("truncated package")
        }

        // Keep the compressed member in the package file and process the
        // decompressed CPIO stream in chunks. Only four target bodies stay
        // in memory; no multi-gigabyte temporary file is needed.
        let extractor = CPIOSelectiveExtractor(wanted: Set(Self.requiredFiles.map(\.path)))
        try Bzip2.decompress(source: packageURL,
                              offset: xar.heapBase + payload.offset,
                              length: payload.length) { chunk in
            try extractor.consume(chunk)
        }
        try extractor.finish()

        var found: [String: Data] = [:]
        for spec in Self.requiredFiles {
            guard let body = extractor.files[spec.path] else {
                throw SAPAssetsError.missingFile(spec.name)
            }
            guard body.count == spec.size else {
                throw SAPAssetsError.digestMismatch(spec.name)
            }
            found[spec.name] = body
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
