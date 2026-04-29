import Foundation

/// Creates the appropriate `Decoder` implementation for a given URL.
///
/// Selection is based solely on magic-byte detection via `FormatSniffer` —
/// file extensions are never used for routing.
public struct DecoderFactory: Sendable {
    /// AVFoundation-native codecs — no FFmpeg required.
    static let avFoundationCodecs: Set<Codec> = [.wav, .flac, .mp3, .m4a]

    public init() {}

    /// Instantiate the correct decoder for `url`.
    ///
    /// - Throws: `AudioEngineError.fileNotFound` if the file doesn't exist,
    ///   `AudioEngineError.unsupportedFormat` if no decoder handles the format.
    public static func make(for url: URL) throws -> any Decoder {
        let sniffer = FormatSniffer()
        let codec = try sniffer.sniff(url: url)
        return try self.make(codec: codec, url: url)
    }

    static func make(codec: Codec, url: URL) throws -> any Decoder {
        switch codec {
        case .wav, .mp3, .m4a:
            return try AVFoundationDecoder(url: url)

        case .flac:
            // AVFoundation's FLAC decoder supports up to 24-bit / 384 kHz but
            // refuses unusual high-resolution streams (e.g. 32-bit float, very
            // large block sizes).  Fall back to FFmpeg in that case so the
            // file plays instead of throwing `decoderFailure`.
            do {
                return try AVFoundationDecoder(url: url)
            } catch let error as AudioEngineError {
                if case .accessDenied = error { throw error }
                if case .fileNotFound = error { throw error }
                if let ffmpeg = try? FFmpegDecoder(url: url) {
                    return ffmpeg
                }
                throw error
            }

        case .ogg, .opus, .dsf, .dff, .ape, .wavpack:
            return try FFmpegDecoder(url: url)

        case let .unknown(magic):
            // Last resort: try FFmpeg — it may recognise formats we don't.
            if let decoder = try? FFmpegDecoder(url: url) {
                return decoder
            }
            throw AudioEngineError.unsupportedFormat(magic: magic, url: url)
        }
    }
}
