import Foundation

/// Minimal Mach-O (x86_64) parser: header, load commands (LC_SEGMENT_64,
/// LC_SYMTAB, LC_DYLD_INFO[_ONLY]), symbol table, dyld compressed
/// rebase/bind streams, fat-binary slicing. No external dependencies.
///
/// Clean-room port of the *behavior* of ipatool's machimage package (MIT),
/// reimplemented against the documented Mach-O and dyld compressed-fixup
/// formats.
public struct MachOFile {

    public enum Error: Swift.Error, Equatable {
        case truncated
        case badMagic
        case notX86_64
        case noX86Slice
        case symbolNotFound(String)
        case fixupOutOfRange
    }

    public struct Segment: Sendable, Equatable {
        public let name: String
        public let vmaddr: UInt64
        public let vmsize: UInt64
        public let fileoff: UInt64
        public let filesize: UInt64
    }

    public struct Rebase: Sendable, Equatable {
        public let segmentIndex: Int
        public let segmentOffset: UInt64
        public let type: UInt8
    }

    public struct Bind: Sendable, Equatable {
        public let segmentIndex: Int
        public let segmentOffset: UInt64
        public let type: UInt8
        public let symbolName: String
        public let addend: Int64
    }

    public let data: Data
    public let baseAddress: UInt64
    public internal(set) var segments: [Segment] = []
    public private(set) var symbols: [String: UInt64] = [:]
    public private(set) var rebases: [Rebase] = []
    public private(set) var binds: [Bind] = []

    private static let MH_MAGIC_64: UInt32 = 0xFEEDFACF
    private static let FAT_MAGIC: UInt32 = 0xCAFEBABE
    private static let FAT_MAGIC_64: UInt32 = 0xCAFEBABF
    private static let CPU_TYPE_X86_64: UInt32 = 0x01000007

    private static let LC_SEGMENT_64: UInt32 = 0x19
    private static let LC_SYMTAB: UInt32 = 0x2
    private static let LC_DYLD_INFO: UInt32 = 0x22
    private static let LC_DYLD_INFO_ONLY: UInt32 = 0x80000022

    /// Slice the x86_64 image out of a fat binary, or accept a thin one.
    public static func sliceX86_64(from input: Data) throws -> Data {
        guard input.count >= 8 else { throw Error.truncated }
        let magicLE = readLE32(input, at: 0)
        if magicLE == MH_MAGIC_64 { return input }

        let magicBE = readBE32(input, at: 0)
        guard magicBE == FAT_MAGIC || magicBE == FAT_MAGIC_64 else { throw Error.badMagic }
        let is64 = magicBE == FAT_MAGIC_64
        let archCount = readBE32(input, at: 4)
        var cursor = 8
        let entrySize = is64 ? 32 : 20
        for _ in 0..<archCount {
            guard input.count >= cursor + entrySize else { throw Error.truncated }
            let cpu = readBE32(input, at: cursor)
            let offset: UInt64 = is64 ? readBE64(input, at: cursor + 8) : UInt64(readBE32(input, at: cursor + 8))
            let size: UInt64 = is64 ? readBE64(input, at: cursor + 16) : UInt64(readBE32(input, at: cursor + 12))
            if cpu == CPU_TYPE_X86_64 {
                let end = Int(offset) + Int(size)
                guard end <= input.count else { throw Error.truncated }
                return input.subdata(in: Int(offset)..<end)
            }
            cursor += entrySize
        }
        throw Error.noX86Slice
    }

    public init(data raw: Data) throws {
        let sliced = try Self.sliceX86_64(from: raw)
        self.data = sliced

        guard sliced.count >= 32 else { throw Error.truncated }
        guard Self.readLE32(sliced, at: 0) == Self.MH_MAGIC_64 else { throw Error.badMagic }
        guard Self.readLE32(sliced, at: 4) == Self.CPU_TYPE_X86_64 else { throw Error.notX86_64 }

        let ncmds = Self.readLE32(sliced, at: 16)
        let sizeofcmds = Self.readLE32(sliced, at: 20)

        var symtab: (symoff: UInt32, nsyms: UInt32, stroff: UInt32)?
        var dyldInfo: (rebaseOff: UInt32, rebaseSize: UInt32, bindOff: UInt32, bindSize: UInt32,
                       lazyBindOff: UInt32, lazyBindSize: UInt32)?

        var cursor = 32
        let commandsEnd = min(32 + Int(sizeofcmds), sliced.count)
        for _ in 0..<ncmds {
            guard cursor + 8 <= commandsEnd else { break }
            let cmd = Self.readLE32(sliced, at: cursor)
            let cmdsize = Int(Self.readLE32(sliced, at: cursor + 4))
            guard cmdsize >= 8, cursor + cmdsize <= sliced.count else { break }

            switch cmd {
            case Self.LC_SEGMENT_64:
                let nameBytes = sliced.subdata(in: (cursor + 8)..<(cursor + 24))
                let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
                segments.append(Segment(
                    name: name,
                    vmaddr: Self.readLE64(sliced, at: cursor + 24),
                    vmsize: Self.readLE64(sliced, at: cursor + 32),
                    fileoff: Self.readLE64(sliced, at: cursor + 40),
                    filesize: Self.readLE64(sliced, at: cursor + 48)
                ))
            case Self.LC_SYMTAB:
                symtab = (Self.readLE32(sliced, at: cursor + 8), Self.readLE32(sliced, at: cursor + 12),
                          Self.readLE32(sliced, at: cursor + 16))
            case Self.LC_DYLD_INFO, Self.LC_DYLD_INFO_ONLY:
                dyldInfo = (Self.readLE32(sliced, at: cursor + 8), Self.readLE32(sliced, at: cursor + 12),
                            Self.readLE32(sliced, at: cursor + 16), Self.readLE32(sliced, at: cursor + 20),
                            Self.readLE32(sliced, at: cursor + 24), Self.readLE32(sliced, at: cursor + 28))
            default:
                break
            }
            cursor += cmdsize
        }

        self.baseAddress = segments
            .filter { $0.name != "__PAGEZERO" && $0.vmsize > 0 }
            .map(\.vmaddr)
            .min() ?? 0

        if let symtab {
            let symoff = Int(symtab.symoff), nsyms = Int(symtab.nsyms), stroff = Int(symtab.stroff)
            for index in 0..<nsyms {
                let entryOff = symoff + index * 16
                guard entryOff + 16 <= sliced.count else { break }
                let strx = Int(Self.readLE32(sliced, at: entryOff))
                let value = Self.readLE64(sliced, at: entryOff + 8)
                let nameOff = stroff + strx
                guard nameOff < sliced.count else { continue }
                let name = Self.readCString(sliced, at: nameOff)
                if !name.isEmpty { symbols[name] = value }
            }
        }

        if let info = dyldInfo {
            rebases = parseRebases(
                sliced, offset: Int(info.rebaseOff), size: Int(info.rebaseSize))
            binds = parseBinds(
                sliced, offset: Int(info.bindOff), size: Int(info.bindSize))
            binds += parseBinds(
                sliced, offset: Int(info.lazyBindOff), size: Int(info.lazyBindSize))
        }
    }

    public func symbolAddress(_ name: String) -> UInt64? {
        symbols[name]
    }

    /// Return a copy with new underlying bytes but identical layout
    /// (used after in-place relocation patching).
    func replacingData(with newData: Data) -> MachOFile {
        var copy = self
        copy = MachOFile(uncheckedData: newData, baseAddress: baseAddress,
                         segments: segments, symbols: symbols, rebases: rebases, binds: binds)
        return copy
    }

    init(uncheckedData: Data, baseAddress: UInt64, segments: [Segment],
         symbols: [String: UInt64], rebases: [Rebase], binds: [Bind]) {
        self.data = uncheckedData
        self.baseAddress = baseAddress
        self.segments = segments
        self.symbols = symbols
        self.rebases = rebases
        self.binds = binds
    }

    // MARK: - dyld compressed fixup streams

    private enum FixupKind { case rebase, bind }

    private func parseRebases(_ data: Data, offset: Int, size: Int) -> [Rebase] {
        parseFixupStream(data, offset: offset, size: size, kind: .rebase).compactMap { $0 as? Rebase }
    }
    private func parseBinds(_ data: Data, offset: Int, size: Int) -> [Bind] {
        parseFixupStream(data, offset: offset, size: size, kind: .bind).compactMap { $0 as? Bind }
    }

    private func parseFixupStream(_ data: Data, offset: Int, size: Int, kind: FixupKind) -> [Any] {
        guard size > 0, offset >= 0, offset + size <= data.count else { return [] }

        var rebases: [Rebase] = []
        var binds: [Bind] = []
        var cursor = offset
        let end = offset + size

        var type: UInt8 = 1 // REBASE_TYPE_POINTER / BIND_TYPE_POINTER
        var segmentIndex = 0
        var segmentOffset: UInt64 = 0
        var addend: Int64 = 0
        var symbolName = ""

        func readULEB(_ cursor: inout Int) -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while cursor < end {
                let byte = data[cursor]
                cursor += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        func readSLEB(_ cursor: inout Int) -> Int64? {
            var value: Int64 = 0
            var shift: Int64 = 0
            var byte: UInt8 = 0
            while cursor < end {
                byte = data[cursor]
                cursor += 1
                value |= Int64(byte & 0x7F) << shift
                shift += 7
                if byte & 0x80 == 0 {
                    if shift < 64 && (byte & 0x40) != 0 {
                        value |= -(1 << shift)
                    }
                    return value
                }
            }
            return nil
        }

        func readCStringAtCursor(_ cursor: inout Int) -> String? {
            guard cursor < end else { return nil }
            var strEnd = cursor
            while strEnd < end && data[strEnd] != 0 { strEnd += 1 }
            let s = String(data: data.subdata(in: cursor..<strEnd), encoding: .utf8) ?? ""
            cursor = min(strEnd + 1, end)
            return s
        }

        func emitRebase() {
            rebases.append(Rebase(segmentIndex: segmentIndex, segmentOffset: segmentOffset, type: type))
            segmentOffset += 8
        }
        func emitBind() {
            binds.append(Bind(segmentIndex: segmentIndex, segmentOffset: segmentOffset,
                              type: type, symbolName: symbolName, addend: addend))
            segmentOffset += 8
        }

        while cursor < end {
            let byte = data[cursor]
            cursor += 1
            let opcode = byte & 0xF0
            let imm = UInt64(byte & 0x0F)

            switch (kind, opcode) {
            case (_, 0x00): // DONE
                cursor = end
            case (_, 0x10): // SET_TYPE_IMM
                type = UInt8(imm)
            case (_, 0x20): // SET_SEGMENT_AND_OFFSET_ULEB
                segmentIndex = Int(imm)
                guard let v = readULEB(&cursor) else { return kind == .rebase ? rebases : binds }
                segmentOffset = v
            case (.rebase, 0x30): // REBASE ADD_ADDR_ULEB
                guard let v = readULEB(&cursor) else { return rebases }
                segmentOffset += v
            case (.rebase, 0x40): // REBASE ADD_ADDR_IMM_SCALED
                segmentOffset += imm * 8
            case (.rebase, 0x50): // REBASE DO_REBASE_IMM_TIMES
                for _ in 0..<imm { emitRebase() }
            case (.rebase, 0x60): // REBASE DO_REBASE_ULEB_TIMES
                guard let count = readULEB(&cursor) else { return rebases }
                for _ in 0..<count { emitRebase() }
            case (.rebase, 0x70): // REBASE DO_REBASE_ADD_ADDR_ULEB
                emitRebase()
                guard let v = readULEB(&cursor) else { return rebases }
                segmentOffset += v
            case (.rebase, 0x80): // REBASE DO_REBASE_ULEB_TIMES_SKIPPING_ULEB
                guard let count = readULEB(&cursor), let skip = readULEB(&cursor) else { return rebases }
                for _ in 0..<count {
                    emitRebase()
                    segmentOffset += skip
                }
            case (.bind, 0x30): // BIND SET_DYLIB_ORDINAL_IMM
                break
            case (.bind, 0x40): // BIND SET_DYLIB_ORDINAL_ULEB
                _ = readULEB(&cursor)
            case (.bind, 0x50): // BIND SET_DYLIB_SPECIAL_IMM
                break
            case (.bind, 0x60): // BIND SET_SYMBOL_TRAILING_FLAGS_IMM
                guard let s = readCStringAtCursor(&cursor) else { return binds }
                symbolName = s
            case (.bind, 0x70): // BIND SET_TYPE_IMM
                type = UInt8(imm)
            case (.bind, 0x80): // BIND SET_ADDEND_SLEB
                guard let v = readSLEB(&cursor) else { return binds }
                addend = v
            case (.bind, 0x90): // BIND SET_SEGMENT_AND_OFFSET_ULEB
                segmentIndex = Int(imm)
                guard let v = readULEB(&cursor) else { return binds }
                segmentOffset = v
            case (.bind, 0xA0): // BIND ADD_ADDR_ULEB
                guard let v = readULEB(&cursor) else { return binds }
                segmentOffset += v
            case (.bind, 0xB0): // BIND DO_BIND
                emitBind()
            case (.bind, 0xC0): // BIND DO_BIND_ADD_ADDR_ULEB
                emitBind()
                guard let v = readULEB(&cursor) else { return binds }
                segmentOffset += v
            case (.bind, 0xD0): // BIND DO_BIND_ADD_ADDR_IMM_SCALED
                emitBind()
                segmentOffset += imm * 8
            case (.bind, 0xE0): // BIND DO_BIND_ULEB_TIMES_SKIPPING_ULEB
                guard let count = readULEB(&cursor), let skip = readULEB(&cursor) else { return binds }
                for _ in 0..<count {
                    emitBind()
                    segmentOffset += skip
                }
            default:
                break
            }
        }

        return kind == .rebase ? rebases : binds
    }

    // MARK: - Low-level readers

    static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
    }
    static func readLE64(_ data: Data, at offset: Int) -> UInt64 {
        data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt64.self) }
    }
    static func readBE32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(bigEndian: data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) })
    }
    static func readBE64(_ data: Data, at offset: Int) -> UInt64 {
        UInt64(bigEndian: data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt64.self) })
    }
    static func readCString(_ data: Data, at offset: Int) -> String {
        guard offset < data.count else { return "" }
        var end = offset
        while end < data.count && data[end] != 0 { end += 1 }
        return String(data: data.subdata(in: offset..<end), encoding: .utf8) ?? ""
    }
}
