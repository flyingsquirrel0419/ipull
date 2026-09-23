import XCTest
@testable import AppStoreCore

final class Bzip2StreamTests: XCTestCase {

    func testStreamingDecompressMatchesOriginal() throws {
        let bzip2Path = "/usr/bin/bzip2"
        guard FileManager.default.fileExists(atPath: bzip2Path) else {
            throw XCTSkip("bzip2 CLI not available on this host")
        }

        let original = Data((0..<200_000).map { UInt8($0 % 251) })
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("bz-raw-\(UUID().uuidString)")
        try original.write(to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bzip2Path)
        process.arguments = ["-k", "-f", raw.path]
        try process.run()
        process.waitUntilExit()

        let compressedURL = URL(fileURLWithPath: raw.path + ".bz2")
        guard FileManager.default.fileExists(atPath: compressedURL.path) else {
            throw XCTSkip("bzip2 produced no output")
        }
        defer { try? FileManager.default.removeItem(at: compressedURL) }

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("bz-out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        try Bzip2.decompressToFile(source: compressedURL, destination: destination)

        let streamed = try Data(contentsOf: destination)
        XCTAssertEqual(streamed, original, "streaming decompression must match the original bytes")
    }
}
