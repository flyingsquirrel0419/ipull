import XCTest
import CZlib
@testable import AppStoreCore

final class XARReaderTests: XCTestCase {

    /// Build a minimal in-memory XAR: header + zlib TOC + heap with payload.
    private func makeXAR() throws -> Data {
        let toc = """
        <?xml version="1.0"?>
        <xar><toc><file><name>Payload</name><data><offset>0</offset><length>11</length></data></file></toc></xar>
        """
        let tocData = Data(toc.utf8)
        let compressed = try compressZlib(tocData)

        var data = Data()
        data.append(UInt32(0x78617221).bigEndianData)   // magic "xar!"
        data.append(UInt16(28).bigEndianData)           // header size
        data.append(UInt16(1).bigEndianData)            // version
        data.append(UInt64(compressed.count).bigEndianData)
        data.append(UInt64(tocData.count).bigEndianData)
        data.append(UInt32(1).bigEndianData)            // cksum alg (unused)
        data.append(compressed)
        data.append(Data("hello world".utf8))          // heap payload
        return data
    }

    func testParsesHeaderAndTOC() throws {
        let xar = try XARReader(data: makeXAR())
        XCTAssertEqual(xar.entries.count, 1)
        XCTAssertEqual(xar.entries[0].name, "Payload")
        XCTAssertEqual(xar.entries[0].length, 11)
    }

    func testExtractsEntryBytes() throws {
        let data = try makeXAR()
        let xar = try XARReader(data: data)
        let entry = try XCTUnwrap(xar.entry(named: "Payload"))
        let bytes = try XCTUnwrap(xar.bytes(of: entry, in: data))
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "hello world")
    }

    func testRejectsBadMagic() {
        XCTAssertThrowsError(try XARReader(data: Data(repeating: 0, count: 64)))
    }
}

private extension FixedWidthInteger {
    var bigEndianData: Data {
        withUnsafeBytes(of: self.bigEndian) { Data($0) }
    }
}

private func compressZlib(_ data: Data) throws -> Data {
    let bound = czlib_deflate_bound(data.count)
    var out = Data(count: bound)
    let written = data.withUnsafeBytes { srcPtr -> Int in
        out.withUnsafeMutableBytes { dstPtr -> Int in
            let result = czlib_deflate(
                srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                dstPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), bound
            )
            return result < 0 ? 0 : Int(result)
        }
    }
    guard written > 0 else { throw NSError(domain: "test", code: 1) }
    return out.prefix(written)
}
