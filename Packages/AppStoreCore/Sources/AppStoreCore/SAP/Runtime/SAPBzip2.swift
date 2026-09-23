import Foundation
import CBzip2

/// bzip2 decompression via the system libbz2 (present on iOS).
public enum Bzip2 {
    public enum Error: Swift.Error {
        case decompressionFailed
    }

    /// Decompress a bzip2 stream. When the input lacks the leading "BZh"
    /// magic (Apple's raw Payload stream starts after it), the caller must
    /// prepend it — see SAPAssets.
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
}
