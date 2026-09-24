import Foundation
import CZlib

/// Minimal XAR (eXtensible ARchive) reader sufficient for Apple's software
/// update packages: parses the header + zlib-compressed XML table of
/// contents, locates the named payload file, and exposes its byte range.
public struct XARReader {

    public struct Entry: Sendable, Equatable {
        public let name: String
        public let offset: UInt64   // offset within heap
        public let length: UInt64
    }

    public let heapBase: UInt64
    public let entries: [Entry]

    public enum Error: Swift.Error {
        case badMagic
        case truncated
        case badTOC
    }

    public init(data: Data) throws {
        guard data.count >= 28 else { throw Error.truncated }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        guard magic == 0x7861_7221 else { throw Error.badMagic } // "xar!"

        let headerSize = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }.bigEndian
        let tocCompressed = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }.bigEndian
        let tocUncompressed = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self) }.bigEndian

        let tocStart = Int(headerSize)
        let tocEnd = tocStart + Int(tocCompressed)
        guard data.count >= tocEnd else { throw Error.truncated }

        let compressedTOC = data.subdata(in: tocStart..<tocEnd)
        guard let tocXML = XARReader.inflate(compressedTOC, expectedSize: Int(tocUncompressed)),
              let text = String(data: tocXML, encoding: .utf8)
        else { throw Error.badTOC }

        self.heapBase = UInt64(tocEnd)
        self.entries = XARReader.parseTOC(text)
    }

    public func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// Extract the raw (possibly encoded) bytes of an entry from the heap.
    public func bytes(of entry: Entry, in data: Data) -> Data? {
        let start = Int(heapBase + entry.offset)
        let end = start + Int(entry.length)
        guard data.count >= end else { return nil }
        return data.subdata(in: start..<end)
    }

    // MARK: - TOC parsing (flat, attribute-based; Apple's update TOCs are simple)

    static func parseTOC(_ xml: String) -> [Entry] {
        var entries: [Entry] = []
        // Real Apple TOCs use <file id="…">, while small fixtures use <file>.
        let pattern = try! NSRegularExpression(pattern: #"<file(?:\s+[^>]*)?>"#)
        let nsXML = xml as NSString
        for match in pattern.matches(in: xml, range: NSRange(location: 0, length: nsXML.length)) {
            let start = match.range.location + match.range.length
            guard let close = xml.range(of: "</file>", range: Range(NSRange(location: start, length: nsXML.length - start), in: xml)!) else {
                continue
            }
            let block = String(xml[String.Index(utf16Offset: start, in: xml)..<close.lowerBound])
            guard let name = value(of: "name", in: block),
                  let offsetRaw = value(of: "offset", in: block).flatMap(UInt64.init),
                  let lengthRaw = value(of: "length", in: block).flatMap(UInt64.init)
            else { continue }
            entries.append(Entry(name: name, offset: offsetRaw, length: lengthRaw))
        }
        return entries
    }

    private static func value(of tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<" + tag + ">"),
              let close = text.range(of: "</" + tag + ">", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    // MARK: - zlib inflate

    static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        data.withUnsafeBytes { srcPtr -> Data? in
            guard let srcBase = srcPtr.baseAddress else { return nil }
            var out = Data(count: expectedSize)
            let written = out.withUnsafeMutableBytes { dstPtr -> Int in
                guard let dstBase = dstPtr.baseAddress else { return 0 }
                let result = czlib_inflate(
                    srcBase.assumingMemoryBound(to: UInt8.self), data.count,
                    dstBase.assumingMemoryBound(to: UInt8.self), expectedSize
                )
                return result < 0 ? 0 : Int(result)
            }
            guard written > 0 else { return nil }
            return out.prefix(written)
        }
    }
}
