import XCTest
@testable import AppStoreCore

final class RebaseDiagTests: XCTestCase {
    func testDumpBadRebases() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CommerceKit.macho")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip() }
        let file = try MachOFile(data: try Data(contentsOf: url))
        print("rebase count:", file.rebases.count)
        print("bind count:", file.binds.count)
        // First 8 binds for comparison with the python reference decode
        for b in file.binds.prefix(8) {
            print("bind: seg \(b.segmentIndex) off \(String(b.segmentOffset, radix: 16)) sym \(b.symbolName)")
        }
        let bad = file.binds.filter { $0.segmentOffset > 10_000_000 }
        print("bad binds:", bad.count)
        for b in bad.prefix(5) {
            print("badbind: seg \(b.segmentIndex) off \(String(b.segmentOffset, radix: 16)) sym \(b.symbolName)")
        }
    }
}
