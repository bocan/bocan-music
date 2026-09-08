import Foundation

// MARK: - FFmpegInternalError

/// The decoder's own error vocabulary, surfaced through
/// `AudioEngineError.decoderFailure(codec:underlying:)`. Module-internal so
/// `FFmpegDecoder.swift` stays inside the lint length limit; the `ffError`
/// helper that builds `.code` stays file-private there.
enum FFmpegInternalError: Error, LocalizedError {
    case code(Int32, String)
    case noStream
    case noDecoder
    case alloc

    var errorDescription: String? {
        switch self {
        case let .code(_, msg):
            msg

        case .noStream:
            "No audio stream found"

        case .noDecoder:
            "No decoder found for codec"

        case .alloc:
            "Memory allocation failed"
        }
    }
}
