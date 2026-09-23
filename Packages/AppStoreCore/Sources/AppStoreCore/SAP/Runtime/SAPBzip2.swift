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
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        guard let stream = cbzip2_stream_init() else { throw Error.decompressionFailed }
        defer { cbzip2_stream_end(stream) }

        let inChunkSize = 4 * 1024 * 1024
        let outChunkSize = 16 * 1024 * 1024

        while true {
            let inChunk = try input.read(upToCount: inChunkSize) ?? Data()
            try pump(stream: stream, input: inChunk, output: output, outChunkSize: outChunkSize)
            if inChunk.isEmpty { break }
            if cbzip2_stream_finished(stream) != 0 { break }
        }
    }

    /// Feed one input chunk and drain output until the stream wants more
    /// input or finishes.
    private static func pump(stream: OpaquePointer, input: Data, output: FileHandle, outChunkSize: Int) throws {
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
                do { try output.write(contentsOf: outBuffer.prefix(result)) }
                catch { throw Error.fileWriteFailed }
            }
            if cbzip2_stream_finished(stream) != 0 { return }
            if consumed == 0 && result == 0 { return }  // needs more input
        }
    }
}
