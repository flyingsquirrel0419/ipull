import XCTest
@testable import AppStoreCore

final class SHA256Tests: XCTestCase {
    func testKnownVector() {
        // SHA-256 of "abc" — published test vector.
        let hash = SHA256Streamer.hash(data: Data("abc".utf8))
        XCTAssertEqual(hash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testEmptyInput() {
        let hash = SHA256Streamer.hash(data: Data())
        XCTAssertEqual(hash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testFileStreamingMatchesDataHash() throws {
        let payload = Data((0..<100_000).map { UInt8($0 % 251) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sha256-test.bin")
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let streamed = try SHA256Streamer.hash(fileAt: url, chunkSize: 1024)
        let direct = SHA256Streamer.hash(data: payload)
        XCTAssertEqual(streamed, direct)
    }
}
