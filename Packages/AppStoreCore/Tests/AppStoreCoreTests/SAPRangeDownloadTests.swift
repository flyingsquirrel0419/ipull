import XCTest
@testable import AppStoreCore

final class SAPRangeDownloadTests: XCTestCase {

    /// The ranged-extraction path must refuse a server that ignores Range:
    /// answering 200 (full package) instead of 206 aborts instead of
    /// silently downloading 1,217 MB.
    func testRangedDownloadRequires206() async throws {
        final class FullOnly: StreamingHTTPClient, @unchecked Sendable {
            func send(_ request: HTTPRequest, body: Data?) async throws -> HTTPResponse {
                throw AppStoreError.networkUnavailable
            }
            func download(_ request: HTTPRequest, to destination: URL,
                          progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> HTTPResponse {
                FileManager.default.createFile(atPath: destination.path, contents: Data([0x42, 0x5a]))
                return HTTPResponse(statusCode: 200, headers: [:], data: Data())
            }
        }
        let assets = SAPAssets(http: FullOnly(), cacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("ipull-test-\(UUID().uuidString)"))
        do {
            _ = try await assets.load()
            XCTFail("expected failure when Range is ignored")
        } catch SAPAssetsError.downloadFailed {
            // expected
        }
    }
    final class RangeHTTP: StreamingHTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var attempts: [String: Int] = [:]

        private func record(_ range: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            attempts[range, default: 0] += 1
            return attempts[range]!
        }

        func send(_ request: HTTPRequest, body: Data?) async throws -> HTTPResponse {
            throw AppStoreError.networkUnavailable
        }

        func download(_ request: HTTPRequest, to destination: URL,
                      progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> HTTPResponse {
            let range = request.headers["Range"]!
            let attempt = record(range)
            if range == "bytes=0-3" && attempt == 1 {
                throw AppStoreError.networkUnavailable
            }
            let bounds = range.dropFirst("bytes=".count).split(separator: "-")
            let start = Int(bounds[0])!
            let end = Int(bounds[1])!
            let bytes = Data(repeating: UInt8(start), count: end - start + 1)
            progress?(Int64(bytes.count), Int64(bytes.count))
            try bytes.write(to: destination)
            return HTTPResponse(statusCode: 206,
                                headers: ["Content-Range": "bytes \(start)-\(end)/20"], data: Data())
        }

        func count(for range: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return attempts[range, default: 0]
        }
    }

    func testSmallRangesRetryAndReassembleInOrder() async throws {
        let http = RangeHTTP()
        let assets = SAPAssets(http: http)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipull-range-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await assets.performParallelDownload(
            request: HTTPRequest(url: URL(string: "https://example.com/file")!),
            to: destination, totalSize: 20, rangeSize: 4)

        let data = try Data(contentsOf: destination)
        XCTAssertEqual(data.count, 20)
        let expected: [UInt8] = ([(0, 4), (4, 4), (8, 2), (10, 4), (14, 4), (18, 2)] as [(Int, Int)])
            .flatMap { value, count in [UInt8](repeating: UInt8(value), count: count) }
        XCTAssertEqual(Array(data), expected)
        XCTAssertEqual(http.count(for: "bytes=0-3"), 2)
    }
}
