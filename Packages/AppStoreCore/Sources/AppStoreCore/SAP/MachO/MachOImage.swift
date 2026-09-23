import Foundation

/// A parsed Mach-O image that can be relocated against a target base and
/// written into emulated memory. Behavior mirrors ipatool's machimage
/// (MIT) — implemented against the documented Mach-O/dyld formats.
public struct MachOImage {

    /// Destination for relocated image bytes.
    public protocol Memory {
        func map(address: UInt64, size: UInt64) throws
        func write(address: UInt64, data: Data) throws
    }

    public enum Error: Swift.Error, Equatable {
        case alreadyRelocated
        case notRelocated
        case symbolBelowBase(String)
        case fixupOverflow
        case segmentTooLarge(String)
        case unknownSegment(String)
        case imageTooLarge
    }

    public let name: String
    public private(set) var file: MachOFile
    public private(set) var relocated = false
    public private(set) var loadedBase: UInt64 = 0

    private static let pageSize: UInt64 = 0x1000
    private static let maxImageSpan: UInt64 = 1 << 30
    private static let pointerSize: UInt64 = 8

    public init(name: String, data: Data) throws {
        self.name = name
        self.file = try MachOFile(data: data)
    }

    /// Address of an exported symbol after loading at the given base.
    public func exportAddress(_ name: String, loadBase: UInt64) throws -> UInt64 {
        guard let address = file.symbolAddress(name) else {
            throw MachOFile.Error.symbolNotFound(name)
        }
        guard address >= file.baseAddress else { throw Error.symbolBelowBase(name) }
        let (result, overflow) = loadBase.addingReportingOverflow(address - file.baseAddress)
        if overflow { throw Error.fixupOverflow }
        return result
    }

    /// Apply pointer rebases and symbol binds against loadBase.
    /// resolve maps an imported symbol name to an address (shim slot).
    public mutating func relocate(loadBase: UInt64, resolve: (String) throws -> UInt64) throws {
        guard !relocated else { throw Error.alreadyRelocated }

        var data = file.data

        for rebase in file.rebases {
            guard rebase.segmentIndex < file.segments.count else {
                throw Error.unknownSegment("rebase #\(rebase.segmentIndex)")
            }
            let segment = file.segments[rebase.segmentIndex]
            let offset = try segmentFileOffset(segment: segment, offset: rebase.segmentOffset, size: Self.pointerSize)
            guard segment.vmaddr >= file.baseAddress else { throw Error.fixupOverflow }
            let (address, overflow) = loadBase.addingReportingOverflow(segment.vmaddr + rebase.segmentOffset - file.baseAddress)
            if overflow { throw Error.fixupOverflow }
            try putPointer(into: &data, at: Int(offset), value: address)
        }

        for bind in file.binds {
            guard bind.segmentIndex < file.segments.count else {
                throw Error.unknownSegment("bind #\(bind.segmentIndex)")
            }
            let segment = file.segments[bind.segmentIndex]
            let offset = try segmentFileOffset(segment: segment, offset: bind.segmentOffset, size: Self.pointerSize)
            var address = try resolve(bind.symbolName)
            if bind.addend >= 0 {
                let (r, overflow) = address.addingReportingOverflow(UInt64(bind.addend))
                if overflow { throw Error.fixupOverflow }
                address = r
            } else {
                let magnitude = UInt64(-(bind.addend + 1)) + 1
                guard magnitude <= address else { throw Error.fixupOverflow }
                address -= magnitude
            }
            try putPointer(into: &data, at: Int(offset), value: address)
        }

        self.file = file.replacingData(with: data)
        self.relocated = true
        self.loadedBase = loadBase
    }

    /// Write all non-__PAGEZERO segments into emulated memory.
    public func load(into memory: Memory) throws {
        guard relocated else { throw Error.notRelocated }

        var span: UInt64 = 0
        for segment in file.segments where segment.name != "__PAGEZERO" && segment.vmsize > 0 {
            guard segment.vmaddr >= file.baseAddress else { throw Error.segmentTooLarge(segment.name) }
            let end = segment.vmaddr - file.baseAddress + segment.vmsize
            if end > Self.maxImageSpan { throw Error.imageTooLarge }
            span = max(span, end)
        }
        span = (span + Self.pageSize - 1) & ~(Self.pageSize - 1)
        guard span > 0 else { throw Error.segmentTooLarge("<none>") }

        try memory.map(address: loadedBase, size: span)

        for segment in file.segments where segment.name != "__PAGEZERO" && segment.filesize > 0 {
            let end = Int(segment.fileoff + segment.filesize)
            guard end <= file.data.count else { throw Error.segmentTooLarge(segment.name) }
            let address = loadedBase + (segment.vmaddr - file.baseAddress)
            try memory.write(address: address, data: file.data.subdata(in: Int(segment.fileoff)..<end))
        }
    }

    private func segmentFileOffset(segment: MachOFile.Segment, offset: UInt64, size: UInt64) throws -> UInt64 {
        let segmentEnd = offset + size
        guard segmentEnd <= segment.vmsize, segmentEnd <= segment.filesize else {
            throw Error.fixupOverflow
        }
        return segment.fileoff + offset
    }

    private func putPointer(into data: inout Data, at offset: Int, value: UInt64) throws {
        guard offset + 8 <= data.count else { throw Error.fixupOverflow }
        data.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt64.self)
        }
    }
}
