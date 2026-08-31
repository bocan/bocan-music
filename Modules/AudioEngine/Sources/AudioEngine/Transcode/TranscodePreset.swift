import Foundation

// MARK: - TranscodePreset

/// A quality rung for sync-and-transcode (ADR-088).
///
/// The raw value is the stable identifier persisted in the `sync_transcodes`
/// ledger and in the sync profile; do not change it. The vocabulary lives
/// here, in AudioEngine, so Persistence stays codec-agnostic.
public enum TranscodePreset: String, CaseIterable, Sendable, Codable {
    case mp3320 = "mp3_320"
    case mp3256 = "mp3_256"
    case opus192 = "opus_192"
    case opus128 = "opus_128"

    /// The target bitrate in kbps: exact for the CBR MP3 rungs, nominal for
    /// the VBR Opus rungs.
    public var targetKbps: Int {
        switch self {
        case .mp3320:
            320

        case .mp3256:
            256

        case .opus192:
            192

        case .opus128:
            128
        }
    }

    /// The artifact's file extension; also what the manifest `relPath` carries.
    public var fileExtension: String {
        switch self {
        case .mp3320, .mp3256:
            "mp3"

        case .opus192, .opus128:
            "opus"
        }
    }

    /// The manifest `format` value for the artifact.
    public var formatName: String {
        switch self {
        case .mp3320, .mp3256:
            "mp3"

        case .opus192, .opus128:
            "opus"
        }
    }

    /// True when the encoder is VBR, so sizes computed from `targetKbps` are
    /// estimates rather than exact.
    public var isVBR: Bool {
        switch self {
        case .mp3320, .mp3256:
            false

        case .opus192, .opus128:
            true
        }
    }

    /// The FFmpeg encoder name.
    var encoderName: String {
        switch self {
        case .mp3320, .mp3256:
            "libmp3lame"

        case .opus192, .opus128:
            "libopus"
        }
    }

    /// The output sample rate for a given source rate: Opus requires 48 kHz;
    /// MP3 keeps a rate it supports and resamples anything else (hi-res
    /// sources included) down to 48 kHz.
    func outputSampleRate(forSourceRate rate: Int32) -> Int32 {
        switch self {
        case .opus192, .opus128:
            48000

        case .mp3320, .mp3256:
            Self.mp3Rates.contains(rate) ? rate : 48000
        }
    }

    /// Sample rates the MP3 format supports (MPEG-1 and MPEG-2 layers).
    private static let mp3Rates: Set<Int32> = [
        8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000,
    ]
}

// MARK: - TranscodeResult

/// What a completed transcode produced: the facts the sync ledger records.
public struct TranscodeResult: Sendable, Equatable {
    /// Lowercase-hex SHA-256 of the artifact bytes.
    public let sha256: String
    /// Artifact size in bytes.
    public let size: Int64
    /// The preset's target bitrate in kbps (nominal for VBR rungs).
    public let bitrateKbps: Int
}
