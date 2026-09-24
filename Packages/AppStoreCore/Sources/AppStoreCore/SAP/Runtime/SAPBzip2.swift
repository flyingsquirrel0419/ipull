import Foundation
import CBzip2

/// bzip2 decompression via the system libbz2 (present on iOS).
public enum Bzip2 {
    public enum Error: Swift.Error {
        case decompressionFailed
        case fileWriteFailed
    }

    /// One-shot decompress for small inputs.
    public static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        var out = Data(count: expectedSize)
        let written = data.withUnsafeBytes { srcPtr -> Int in
            out.withUnsafeMutableBytes { dstPtr -> Int in
                let result = cbzip2_decompress(
                    srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                    dstPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), expectedSize,
                    0
                )
                return result < 0 ? -1 : Int(result)
            }
        }
        guard written >= 0 else { throw Error.decompressionFailed }
        return out.prefix(written)
    }

    /// Streaming decompress to a file — bounded memory. Required on device
    /// for the ~3.6 GB decompressed SAP payload (a contiguous Data of that
    /// size fails under iOS memory limits).
    public static func decompressToFile(source: URL, destination: URL) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.uint64Value ?? 0
        try decompressToFile(source: source, offset: 0, length: size, destination: destination)
    }

    public static func decompressToFile(source: URL, offset: UInt64, length: UInt64,
                                        destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try decompress(source: source, offset: offset, length: length) { chunk in
            try output.write(contentsOf: chunk)
        }
    }

    public static func decompress(source: URL, offset: UInt64, length: UInt64,
                                  consume: (Data) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try input.seek(toOffset: offset)

        guard let stream = cbzip2_stream_init() else { throw Error.decompressionFailed }
        defer { cbzip2_stream_end(stream) }

        let inChunkSize = 4 * 1024 * 1024
        let outChunkSize = 16 * 1024 * 1024

        var remaining = length
        while remaining > 0 {
            let inChunk = try input.read(upToCount: Int(min(UInt64(inChunkSize), remaining))) ?? Data()
            guard !inChunk.isEmpty else { throw Error.decompressionFailed }
            remaining -= UInt64(inChunk.count)
            try pump(stream: stream, input: inChunk, outChunkSize: outChunkSize, consume: consume)
            if cbzip2_stream_finished(stream) != 0 { break }
        }
        guard cbzip2_stream_finished(stream) != 0 else { throw Error.decompressionFailed }
    }

    /// Feed one input chunk and drain output until the stream wants more
    /// input or finishes.
    private static func pump(stream: OpaquePointer, input: Data, outChunkSize: Int,
                             consume: (Data) throws -> Void) throws {
        var offset = 0
        while offset < input.count || cbzip2_stream_finished(stream) == 0 {
            var consumed = 0
            var outBuffer = Data(count: outChunkSize)
            let remaining = input.count - offset
            let slice = input.subdata(in: offset..<input.count)
            let result: Int = slice.withUnsafeBytes { inPtr in
                outBuffer.withUnsafeMutableBytes { outPtr in
                    let r = cbzip2_stream_decompress(
                        stream,
                        inPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), remaining,
                        &consumed,
                        outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), outChunkSize
                    )
                    return r < 0 ? -1 : Int(r)
                }
            }
            if result < 0 { throw Error.decompressionFailed }
            offset += consumed
            if result > 0 {
                try consume(outBuffer.prefix(result))
            }
            if cbzip2_stream_finished(stream) != 0 { return }
            if consumed == 0 && result == 0 { return }  // needs more input
        }
    }
}
