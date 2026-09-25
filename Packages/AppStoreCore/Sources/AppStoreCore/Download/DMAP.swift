import Foundation

/// DMAP (DAAP tagged binary) encoding and walking, ported from ipatool's
/// pkg/appstore/appstore_owned_apps.go. Every element is a 4-byte ASCII tag,
/// a big-endian UInt32 length, then the payload; some tags are containers.
enum DMAP {
    struct ParseError: Error, Equatable {
        let reason: String
    }

    static func tag(_ name: String, _ payload: Data = Data()) -> Data {
        var result = Data(name.utf8.prefix(4))
        result.append(uint32BigEndian(UInt32(payload.count)))
        result.append(payload)
        return result
    }

    static func uint8(_ name: String, _ value: UInt8) -> Data {
        tag(name, Data([value]))
    }

    static func uint32(_ name: String, _ value: UInt32) -> Data {
        tag(name, uint32BigEndian(value))
    }

    static func string(_ name: String, _ value: String) -> Data {
        tag(name, Data(value.utf8))
    }

    private static func uint32BigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static let containers: Set<String> = [
        "adbs", "adsr", "aply", "avdb", "mbcl", "mccr", "mcty", "mdcl", "mlcl", "mlit", "mlog", "msrv", "mupd",
    ]

    /// Depth-first visit of every tag, descending into containers.
    static func walk(_ data: Data, depth: Int = 0, _ visit: (String, Data) throws -> Void) throws {
        guard depth <= 16 else { throw ParseError(reason: "DMAP nesting is too deep") }
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 8 else {
                throw ParseError(reason: "truncated DMAP tag header at byte \(offset)")
            }
            let tagBytes = bytes[offset..<offset + 4]
            guard tagBytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }),
                  let name = String(bytes: tagBytes, encoding: .ascii) else {
                throw ParseError(reason: "invalid DMAP tag at byte \(offset)")
            }
            let length = Int(bytes[offset + 4]) << 24 | Int(bytes[offset + 5]) << 16
                | Int(bytes[offset + 6]) << 8 | Int(bytes[offset + 7])
            guard length <= bytes.count - offset - 8 else {
                throw ParseError(reason: "DMAP tag \(name) length exceeds the response")
            }
            let payload = Data(bytes[offset + 8..<offset + 8 + length])
            try visit(name, payload)
            if containers.contains(name) {
                try walk(payload, depth: depth + 1, visit)
            }
            offset += 8 + length
        }
    }

    /// Big-endian unsigned integer of 1, 2, 4 or 8 bytes.
    static func unsigned(_ payload: Data) -> UInt64? {
        guard [1, 2, 4, 8].contains(payload.count) else { return nil }
        return payload.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// First integer value of `target` (4 or 8 bytes, like ipatool).
    static func firstUInt(_ data: Data, _ target: String) throws -> UInt64? {
        var result: UInt64?
        try walk(data) { name, payload in
            guard result == nil, name == target else { return }
            guard payload.count == 4 || payload.count == 8 else {
                throw ParseError(reason: "tag \(target) has invalid integer length \(payload.count)")
            }
            result = unsigned(payload)
        }
        return result
    }
}
