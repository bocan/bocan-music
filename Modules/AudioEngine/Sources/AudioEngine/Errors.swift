import AVFoundation

/// All errors produced by the `AudioEngine` module.
///
/// Every case carries enough context for both human-readable display and
/// programmatic recovery. The `description` is suitable for logging or
/// surfacing in a UI error sheet.
public enum AudioEngineError: Error, Sendable, CustomStringConvertible {
    case fileNotFound(URL)
    case accessDenied(URL, underlying: Error?)
    case unsupportedFormat(magic: Data, url: URL)
    case decoderFailure(codec: String, underlying: Error)
    case formatConversionFailure(from: AVAudioFormat, to: AVAudioFormat)
    case engineStartFailed(underlying: Error)
    case outputDeviceUnavailable
    case seekOutOfRange(requested: TimeInterval, duration: TimeInterval)
    case cancelled

    public var description: String {
        switch self {
        case let .fileNotFound(url):
            return "File not found: \(url.path)"

        case let .accessDenied(url, err):
            let reason = err.map { ": \($0.localizedDescription)" } ?? ""
            return "Access denied to \(url.path)\(reason)"

        case let .unsupportedFormat(magic, url):
            let hex = magic.map { String(format: "%02x", $0) }.joined(separator: " ")
            return "Unsupported audio format at \(url.lastPathComponent) (magic bytes: \(hex))"

        case let .decoderFailure(codec, err):
            return "Decoder failure [\(codec)]: \(err.localizedDescription)"

        case let .formatConversionFailure(from, to):
            return "Format conversion failed: \(from) → \(to)"

        case let .engineStartFailed(err):
            return "Audio engine failed to start: \(err.localizedDescription)"

        case .outputDeviceUnavailable:
            return "Output audio device is unavailable"

        case let .seekOutOfRange(requested, duration):
            return "Seek \(String(format: "%.2f", requested))s is out of range (duration: \(String(format: "%.2f", duration))s)"

        case .cancelled:
            return "Operation was cancelled"
        }
    }
}
