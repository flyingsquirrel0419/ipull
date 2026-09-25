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
    public static func entries(in data: Data, matching names: Set<String>? = nil) throws -> [Entry] {
        var entries: [Entry] = []
        var cursor = 0

        guard data.count >= headerSize else { throw Error.truncated }
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
            if names == nil || names!.contains(name) {
                let body = data.subdata(in: cursor..<(cursor + fileSize))
                entries.append(Entry(name: name, body: body))
            }
            cursor += fileSize
        }

        return entries
    }

    static func parseOctal(_ data: Data, range: Range<Int>) throws -> Int {
        let text = String(decoding: data.subdata(in: range), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        guard let value = Int(text, radix: 8) else { throw Error.truncated }
        return value
    }
}

/// Reads a CPIO stream one decompressed chunk at a time. Large unrelated
/// files are skipped without keeping their bodies in memory or on disk.
final class CPIOSelectiveExtractor {
    private enum State: Equatable { case header, name, body, done }
    private var state: State = .header
    private var buffer = Data()
    private var nameLength = 0
    private var bodyLength = 0
    private var remainingBody = 0
    private var currentName = ""
    private var selectedBody = Data()
    private let wanted: Set<String>
    private(set) var files: [String: Data] = [:]

    init(wanted: Set<String>) { self.wanted = wanted }

    /// True once every wanted file has been fully read — the caller can
    /// stop feeding the stream (ranged extraction never reaches TRAILER).
    var allFound: Bool { files.count == wanted.count }

    func consume(_ chunk: Data) throws {
        var cursor = 0
        while cursor < chunk.count {
            switch state {
            case .header:
                take(from: chunk, cursor: &cursor, count: 76)
                guard buffer.count == 76 else { continue }
                guard buffer.prefix(6).elementsEqual(Data("070707".utf8)) else {
                    throw CPIOReader.Error.badMagic
                }
                nameLength = try CPIOReader.parseOctal(buffer, range: 59..<65)
                bodyLength = try CPIOReader.parseOctal(buffer, range: 65..<76)
                guard nameLength > 0 else { throw CPIOReader.Error.truncated }
                buffer.removeAll(keepingCapacity: true)
                state = .name
            case .name:
                take(from: chunk, cursor: &cursor, count: nameLength)
                guard buffer.count == nameLength else { continue }
                currentName = String(decoding: buffer.dropLast(), as: UTF8.self)
                buffer.removeAll(keepingCapacity: true)
                if currentName == "TRAILER!!!" {
                    state = .done
                    continue
                }
                remainingBody = bodyLength
                selectedBody = Data()
                if wanted.contains(currentName) {
                    selectedBody.reserveCapacity(bodyLength)
                }
                state = .body
                if remainingBody == 0 { finishBody() }
            case .body:
                let amount = min(remainingBody, chunk.count - cursor)
                if wanted.contains(currentName) {
                    selectedBody.append(chunk[cursor..<(cursor + amount)])
                }
                cursor += amount
                remainingBody -= amount
                if remainingBody == 0 { finishBody() }
            case .done:
                return
            }
        }
    }

    func finish() throws {
        guard state == .done else { throw CPIOReader.Error.truncated }
    }

    private func take(from chunk: Data, cursor: inout Int, count: Int) {
        let amount = min(count - buffer.count, chunk.count - cursor)
        buffer.append(chunk[cursor..<(cursor + amount)])
        cursor += amount
    }

    private func finishBody() {
        if wanted.contains(currentName) {
            files[currentName] = selectedBody
        }
        state = .header
    }
}
