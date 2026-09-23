import XCTest
@testable import AppStoreCore

final class CPIOReaderTests: XCTestCase {

    /// Build a minimal old-ASCII CPIO archive with two files + trailer.
    private func makeCPIO() -> Data {
        func entry(name: String, body: String) -> Data {
            var header = "070707"
            // 70 more bytes of octal fields; only namesize & filesize matter here.
            let nameSize = name.utf8.count + 1
            let fileSize = body.utf8.count
            // Fill dev,ino,mode,uid,gid,nlink,rdev,mtime with zeros (octal, 6/6/6/6/6/6/6/11 chars)
            header += String(repeating: "0", count: 53)  // dev,ino,mode,uid,gid,nlink,rdev(6 each) + mtime(11)
            header += String(format: "%06o", nameSize)
            header += String(format: "%011o", fileSize)
            var data = Data(header.utf8)
            data.append(contentsOf: name.utf8)
            data.append(0)
            data.append(contentsOf: body.utf8)
            return data
        }
        var archive = entry(name: "./a.txt", body: "hello")
        archive.append(entry(name: "./b.bin", body: "world!!"))
        archive.append(entry(name: "TRAILER!!!", body: ""))
        return archive
    }

    func testExtractsEntries() throws {
        let entries = try CPIOReader.entries(in: makeCPIO())
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "./a.txt")
        XCTAssertEqual(String(data: entries[0].body, encoding: .utf8), "hello")
        XCTAssertEqual(String(data: entries[1].body, encoding: .utf8), "world!!")
    }

    func testRejectsBadMagic() {
        XCTAssertThrowsError(try CPIOReader.entries(in: Data("nope".utf8)))
    }
}
