import Foundation

/// Identifies a codec family for routing to the correct decoder back-end.
public enum Codec: Sendable, Equatable, Hashable {
    case wav
    case flac
    case mp3
    case m4a // covers both AAC and ALAC; AVFoundation handles both
    case ogg // Vorbis or Opus inside an Ogg container
    case opus // raw Opus
    case dsf // DSD Stream File (Sony)
    case dff // DSDIFF (Philips)
    case ape // Monkey's Audio
    case wavpack
    case unknown(Data)
}

/// Inspects the first bytes of an audio file to determine its codec.
///
/// Using magic-byte detection is more reliable than file-extension heuristics
/// and is required even when the OS provides format detection, because not all
/// container formats are supported natively.
public struct FormatSniffer: Sendable {
    /// Number of bytes to read from the head of each file.
    ///
    /// 64 bytes covers the standard Ogg page header (28 bytes) plus the
    /// Opus identification header ("OpusHead") that appears at offset 28 in
    /// the first packet of an Opus stream. Anything shorter would force us
    /// back to extension-based heuristics for the OGG-vs-Opus discrimination.
    public static let sniffBytes = 64

    public init() {}

    /// Read up to 16 bytes from `url` and return the detected `Codec`.
    /// Returns `nil` for formats that require FFmpeg probing (i.e. `Codec.unknown`
    /// will never be returned — the codec is `.unknown` only for completely
    /// unrecognisable headers).
    public func sniff(url: URL) throws -> Codec {
        // Read first 16 bytes.
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            if (error as NSError).code == NSFileNoSuchFileError ||
                (error as NSError).code == NSFileReadNoSuchFileError {
                throw AudioEngineError.fileNotFound(url)
            }
            throw AudioEngineError.accessDenied(url, underlying: error)
        }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: Self.sniffBytes)
        return self.sniff(bytes: data, url: url)
    }

    /// Detect codec from raw header bytes.
    ///
    /// - Parameter bytes: At least the first 16 bytes of the file.
    public func sniff(bytes: Data, url: URL = URL(fileURLWithPath: "")) -> Codec {
        guard bytes.count >= 4 else { return .unknown(bytes) }
        return detectContainerCodec(from: bytes) ?? .unknown(bytes.prefix(16))
    }
}

// MARK: - Private helpers

private extension FormatSniffer {
    func detectContainerCodec(from b: Data) -> Codec? {
        // WAV: "RIFF" at offset 0
        if b.hasPrefix("RIFF") { return .wav }

        // FLAC: "fLaC" at offset 0
        if b.hasPrefix("fLaC") { return .flac }

        // MP3: ID3 tag or sync word
        if b.hasPrefix("ID3") { return .mp3 }
        if b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 { return .mp3 }

        // M4A / MP4: "ftyp" at offset 4
        if b.count >= 8, b[4 ..< 8] == Data([0x66, 0x74, 0x79, 0x70]) { return .m4a }

        return self.detectDsdCodec(from: b)
    }

    func detectDsdCodec(from b: Data) -> Codec? {
        // OGG: "OggS" at offset 0.
        // Within an Ogg stream, the first packet begins at offset 28 and
        // tells us whether this is Vorbis, Opus, FLAC, etc.  We look for
        // the "OpusHead" magic — present at offset 28 in any Opus-in-Ogg
        // file — and otherwise fall back to generic Vorbis/Ogg routing.
        if b.hasPrefix("OggS") {
            if b.count >= 36 {
                let opusHead = Data("OpusHead".utf8)
                if b[28 ..< 36] == opusHead {
                    return .opus
                }
            }
            return .ogg
        }

        // DSF (Sony DSD): "DSD " at offset 0
        if b.hasPrefix("DSD ") { return .dsf }

        // DSDIFF: "FRM8" at offset 0
        if b.hasPrefix("FRM8") { return .dff }

        // APE: "MAC " at offset 0
        if b.hasPrefix("MAC ") { return .ape }

        // WavPack: "wvpk" at offset 0
        if b.hasPrefix("wvpk") { return .wavpack }

        return nil
    }
}

// MARK: - Data helpers

private extension Data {
    func hasPrefix(_ string: String) -> Bool {
        let prefix = Data(string.utf8)
        guard self.count >= prefix.count else { return false }
        return self.prefix(prefix.count) == prefix
    }
}
