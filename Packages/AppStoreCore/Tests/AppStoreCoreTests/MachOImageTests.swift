import XCTest
@testable import AppStoreCore

final class MachOImageTests: XCTestCase {

    /// Build the smallest valid x86_64 Mach-O: header + one LC_SEGMENT_64.
    private func makeThinMachO() -> Data {
        var data = Data()
        data.append(UInt32(0xFEEDFACF).littleEndianData) // MH_MAGIC_64
        data.append(UInt32(0x01000007).littleEndianData) // CPU_TYPE_X86_64
        data.append(UInt32(3).littleEndianData)          // cpusubtype
        data.append(UInt32(2).littleEndianData)          // filetype MH_EXECUTE
        data.append(UInt32(1).littleEndianData)          // ncmds
        data.append(UInt32(72).littleEndianData)         // sizeofcmds (LC_SEGMENT_64)
        data.append(UInt32(0).littleEndianData)          // flags
        data.append(UInt32(0).littleEndianData)          // reserved
        // LC_SEGMENT_64: cmd, cmdsize, segname[16], vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, flags
        data.append(UInt32(0x19).littleEndianData)       // LC_SEGMENT_64
        data.append(UInt32(72).littleEndianData)
        var segname = Data(count: 16)
        segname.replaceSubrange(0..<6, with: Data("__TEXT".utf8))
        data.append(segname)
        data.append(UInt64(0x100000000).littleEndianData) // vmaddr
        data.append(UInt64(0x1000).littleEndianData)      // vmsize
        data.append(UInt64(0).littleEndianData)           // fileoff
        data.append(UInt64(0x400).littleEndianData)       // filesize
        data.append(Int32(7).littleEndianData)            // maxprot
        data.append(Int32(5).littleEndianData)            // initprot
        data.append(UInt32(0).littleEndianData)           // nsects
        data.append(UInt32(0).littleEndianData)           // flags
        // pad to filesize
        while data.count < 0x400 { data.append(0) }
        return data
    }

    func testParsesThinImage() throws {
        let image = try MachOImage(name: "test", data: makeThinMachO())
        XCTAssertEqual(image.file.baseAddress, 0x100000000)
        XCTAssertEqual(image.file.segments.count, 1)
        XCTAssertEqual(image.file.segments[0].name, "__TEXT")
    }

    func testRejectsBadMagic() {
        XCTAssertThrowsError(try MachOImage(name: "bad", data: Data(repeating: 0, count: 64)))
    }

    func testRelocateRequiresSegments() throws {
        var image = try MachOImage(name: "t", data: makeThinMachO())
        let mem = FakeMemory()
        try image.relocate(loadBase: 0x0000100000000000) { _ in 0 }
        try image.load(into: mem)
        XCTAssertEqual(mem.mapped.first?.address, 0x0000100000000000)
        XCTAssertEqual(mem.mapped.first?.size, 0x1000)
    }
}

private final class FakeMemory: MachOImage.Memory {
    var mapped: [(address: UInt64, size: UInt64)] = []
    var writes: [(address: UInt64, size: Int)] = []
    func map(address: UInt64, size: UInt64) throws { mapped.append((address, size)) }
    func write(address: UInt64, data: Data) throws { writes.append((address, data.count)) }
}

private extension FixedWidthInteger {
    var littleEndianData: Data { withUnsafeBytes(of: self.littleEndian) { Data($0) } }
}
