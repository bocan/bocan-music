import Compression
import Foundation

/// Produces gzip-framed data (RFC 1952) for `Content-Encoding: gzip`. Apple's
/// Compression framework emits raw DEFLATE (RFC 1951); this wraps it with the
/// gzip header, CRC-32, and ISIZE trailer so a standard gzip decoder (the Android
/// client's HTTP stack) accepts it.
enum Gzip {
    /// Returns `data` gzip-compressed, or `nil` if compression failed (the caller
    /// then serves the body uncompressed).
    static func compress(_ data: Data) -> Data? {
        guard let deflated = rawDeflate(data) else { return nil }

        var out = Data()
        // Header: magic (1f 8b), method DEFLATE (08), flags (0), mtime (0),
        // extra flags (0), OS = Unix (03).
        out.append(contentsOf: [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
        out.append(deflated)
        // Trailer: CRC-32 of the uncompressed data, then ISIZE (size mod 2^32),
        // both little-endian.
        Self.appendLittleEndian(Self.crc32(data), to: &out)
        Self.appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &out)
        return out
    }

    // MARK: - DEFLATE

    private static func rawDeflate(_ data: Data) -> Data? {
        guard !data.isEmpty else {
            // The DEFLATE encoding of the empty string: a single final,
            // stored (uncompressed) block of length zero.
            return Data([0x03, 0x00])
        }
        let capacity = data.count + data.count / 2 + 512
        var destination = Data(count: capacity)
        let written = destination.withUnsafeMutableBytes { destinationBuffer -> Int in
            data.withUnsafeBytes { sourceBuffer -> Int in
                guard
                    let destinationBase = destinationBuffer.bindMemory(to: UInt8.self).baseAddress,
                    let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    destinationBase, capacity,
                    sourceBase, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return Data(destination.prefix(written))
    }

    // MARK: - CRC-32 (IEEE 802.3, polynomial 0xEDB88320)

    private static let crcTable: [UInt32] = (0 ..< 256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0 ..< 8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = Self.crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
