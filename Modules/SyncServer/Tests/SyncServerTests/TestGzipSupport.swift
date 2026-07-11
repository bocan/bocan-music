import Compression
import Foundation

/// Strips gzip framing and raw-inflates the DEFLATE payload. Test-only helper.
enum TestGunzip {
    static func inflate(_ gzip: Data, capacity: Int = 1 << 20) -> Data? {
        guard gzip.count > 18 else { return nil }
        let payload = gzip.subdata(in: 10 ..< (gzip.count - 8))
        var destination = Data(count: capacity)
        let written = destination.withUnsafeMutableBytes { destinationBuffer -> Int in
            payload.withUnsafeBytes { sourceBuffer -> Int in
                guard
                    let destinationBase = destinationBuffer.bindMemory(to: UInt8.self).baseAddress,
                    let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(destinationBase, capacity, sourceBase, payload.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written > 0 ? Data(destination.prefix(written)) : nil
    }
}
