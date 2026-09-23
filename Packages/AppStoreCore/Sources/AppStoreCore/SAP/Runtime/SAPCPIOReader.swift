import Foundation

/// Streaming reader for the old portable ASCII CPIO format used by Apple's
/// software-update Payload. Behavior matches the documented format
/// (76-byte header, octal fields, TRAILER!!! terminator).
public struct CPIOReader {

    public struct Entry {
        public let name: String
        public let body: Data
    }

    public enum Error: Swift.Error {
        case badMagic
        case truncated
    }

    private static let headerSize = 76
    private static let nameSizeOffset = 59
    private static let fileSizeOffset = 65

    /// Extract every entry (fine for the known-small target set).
    public static func entries(in data: Data) throws -> [Entry] {
        var entries: [Entry] = []
        var cursor = 0

        while cursor + headerSize <= data.count {
            let header = data.subdata(in: cursor..<(cursor + headerSize))
            guard header.prefix(6).elementsEqual(Data("070707".utf8)) else {
                throw Error.badMagic
            }
            let nameSize = try parseOctal(header, range: nameSizeOffset..<fileSizeOffset)
            let fileSize = try parseOctal(header, range: fileSizeOffset..<(fileSizeOffset + 11))
            cursor += headerSize

            guard cursor + nameSize <= data.count else { throw Error.truncated }
            let name = String(decoding: data.subdata(in: cursor..<(cursor + nameSize - 1)), as: UTF8.self)
            cursor += nameSize

            if name == "TRAILER!!!" { break }

            guard cursor + fileSize <= data.count else { throw Error.truncated }
            let body = data.subdata(in: cursor..<(cursor + fileSize))
            cursor += fileSize

            entries.append(Entry(name: name, body: body))
        }

        return entries
    }

    private static func parseOctal(_ data: Data, range: Range<Int>) throws -> Int {
        let text = String(decoding: data.subdata(in: range), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        guard let value = Int(text, radix: 8) else { throw Error.truncated }
        return value
    }
}
