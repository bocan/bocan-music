import Foundation

// MARK: - IcyMetadataFramer

/// Encodes ICY/SHOUTcast metadata frames for `E2EStreamServer` (phase 34): the
/// interleaved-metadata half of the ICY wire protocol, factored out as pure
/// byte math so it is unit-testable without a live socket. FFmpeg's ICY
/// reader is unforgiving of a malformed interleave (a wrong length byte
/// silently disables titles rather than erroring), so this is worth getting
/// exactly right in isolation before any network code touches it.
///
/// Wire format (SHOUTcast/ICY spec): after every `icy-metaint` bytes of
/// audio, one length byte gives the metadata block size in units of 16
/// bytes (0 means "no change, no further bytes"); a non-zero block is the
/// metadata text, NUL-padded up to that 16-byte multiple.
enum IcyMetadataFramer {
    /// One interleaved metadata frame. `title == nil` (or empty) sends the
    /// single `0x00` "unchanged" byte real servers use between title
    /// changes; a real title is wrapped as `StreamTitle='...';` and padded.
    static func frame(title: String?) -> Data {
        guard let title, !title.isEmpty else {
            return Data([0x00])
        }
        let text = "StreamTitle='\(Self.escaped(title))';"
        var bytes = Array(text.utf8)
        let paddedLength = ((bytes.count + 15) / 16) * 16
        precondition(
            paddedLength / 16 <= 255,
            "ICY metadata block exceeds the 255*16-byte length-byte limit"
        )
        bytes.append(contentsOf: repeatElement(0, count: paddedLength - bytes.count))
        var frame = Data([UInt8(paddedLength / 16)])
        frame.append(contentsOf: bytes)
        return frame
    }

    /// There is no standard escaping for the single quotes `StreamTitle`
    /// delimits with; doubling them is what real encoders do and what
    /// FFmpeg's own parser tolerates.
    private static func escaped(_ title: String) -> String {
        title.replacingOccurrences(of: "'", with: "''")
    }
}
