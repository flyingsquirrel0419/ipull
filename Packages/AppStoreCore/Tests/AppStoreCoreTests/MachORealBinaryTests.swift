import XCTest
@testable import AppStoreCore

/// Parse the real Apple Mach-O assets (downloaded from swcdn.apple.com at
/// test setup; fixtures are gitignored and fetched by CI when absent).
final class MachORealBinaryTests: XCTestCase {

    private func fixtureURL(_ name: String) -> URL? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func testParsesRealCommerceKit() throws {
        guard let url = fixtureURL("CommerceKit.macho") else {
            throw XCTSkip("fixture not present (CI fetches it)")
        }
        let data = try Data(contentsOf: url)
        let image = try MachOImage(name: "CommerceKit", data: data)

        // All five entry exports must resolve.
        for name in ["_cp2g1b9ro", "_Mib5yocT", "_Fc3vhtJDvr", "_IPaI1oem5iL", "_jEHf8Xzsv8K"] {
            XCTAssertNotNil(image.file.symbolAddress(name), "missing export \(name)")
        }
        XCTAssertFalse(image.file.segments.isEmpty)
    }

    func testParsesRealCoreFP() throws {
        guard let url = fixtureURL("CoreFP") else {
            throw XCTSkip("fixture not present")
        }
        let image = try MachOImage(name: "CoreFP", data: try Data(contentsOf: url))
        XCTAssertFalse(image.file.segments.isEmpty)
    }

    func testRealImagesRelocateAndMap() throws {
        guard let kitURL = fixtureURL("CommerceKit.macho") else {
            throw XCTSkip("fixture not present")
        }
        var image = try MachOImage(name: "CommerceKit", data: try Data(contentsOf: kitURL))
        let memory = FakeMemory()
        try image.relocate(loadBase: 0x0000100080000000) { _ in 0 }
        try image.load(into: memory)
        XCTAssertFalse(memory.mapped.isEmpty)
    }
}

private final class FakeMemory: MachOImage.Memory {
    var mapped: [(address: UInt64, size: UInt64)] = []
    func map(address: UInt64, size: UInt64) throws { mapped.append((address, size)) }
    func write(address: UInt64, data: Data) throws {}
}
