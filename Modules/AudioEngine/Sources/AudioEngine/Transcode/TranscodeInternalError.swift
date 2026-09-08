import Foundation

// MARK: - TranscodeInternalError

/// The transcoder's own error vocabulary, surfaced through
/// `AudioEngineError.decoderFailure` on the read side and `encoderFailure`
/// on the write side. Module-internal so `AudioTranscoder+Pipeline.swift`
/// stays inside the lint length limit; the `ffError`, `checkDecode` and
/// `checkEncode` helpers that build `.code` stay file-private there.
enum TranscodeInternalError: Error, LocalizedError {
    case code(Int32, String)
    case noStream
    case noDecoder
    case noEncoder
    case noAudio
    case alloc

    var errorDescription: String? {
        switch self {
        case let .code(_, msg):
            msg

        case .noStream:
            "No audio stream found"

        case .noDecoder:
            "No decoder found for codec"

        case .noEncoder:
            "Encoder not available in this FFmpeg build"

        case .noAudio:
            "No decodable audio in the source"

        case .alloc:
            "Memory allocation failed"
        }
    }
}
