// @preconcurrency: AVAudioPCMBuffer lacks Sendable; callers own the buffer exclusively.
// Remove once AVFoundation adopts Sendable annotations (FB13119463).
import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import Observability

/// Decodes audio files using `AVAudioFile` — the native macOS decoder.
///
/// Supports WAV (8/16/24/32-bit int, 32/64-bit float), AIFF, FLAC, MP3,
/// AAC and ALAC inside `.m4a` containers. All output is produced in the
/// decoder's `processingFormat` (Float32, non-interleaved) and then up-
/// or down-sampled to the canonical format by `FormatConverter` in `EngineGraph`.
public actor AVFoundationDecoder: Decoder {
    private static let _executor = DispatchSerialQueue(
        label: "com.bocan.avf-decoder",
        qos: .userInitiated
    )
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self._executor.asUnownedSerialExecutor()
    }

    // MARK: - Private state

    // nonisolated: AVAudioFile is Sendable; `processingFormat` and `length` are
    // immutable after init, and `framePosition` is only mutated on the actor's
    // executor by `read(into:)` and `seek(to:)`.
    private nonisolated let file: AVAudioFile
    private let log = AppLogger.make(.audio)

    // MARK: - Public interface

    /// The processing format (`Float32`, non-interleaved) used by `AVAudioFile`.
    public nonisolated var sourceFormat: AVAudioFormat {
        self.file.processingFormat
    }

    /// FFmpeg's short codec name for the file, from the format ID
    /// `AVAudioFile` reports (ADR-092). Measured on macOS 26: the ID is
    /// 'lpcm' for WAV and AIFF, 'flac', '.mp3', 'aac ', 'alac' and 'ec-3'
    /// for E-AC-3 raw or in MP4, so it names the payload where the file
    /// extension names only the container (#529).
    public nonisolated var codec: String? {
        Self.codecName(forFourCC: Self.fourCC(self.file.fileFormat.streamDescription.pointee.mFormatID))
    }

    /// The format IDs whose four-character code is not already FFmpeg's name
    /// for the codec. 'aach' and 'aacp' are HE-AAC v1 and v2; FFmpeg calls
    /// the whole family "aac" and carries the profile separately.
    private static let codecNamesByFormatID: [String: String] = [
        "lpcm": "pcm",
        ".mp3": "mp3",
        ".mp2": "mp2",
        "aac ": "aac",
        "aach": "aac",
        "aacp": "aac",
        "ec-3": "eac3",
        "ac-3": "ac3",
        "vorb": "vorbis",
    ]

    /// Maps a Core Audio four-character format ID onto FFmpeg's short codec
    /// name, so both decoder routes speak one vocabulary. An unmapped code
    /// becomes itself, trimmed and lowercased ('flac', 'alac', 'opus' already
    /// match): a guess, but a codec-shaped one, never a container name.
    /// Internal for `DecoderCodecTests`.
    static func codecName(forFourCC code: String) -> String? {
        if let mapped = codecNamesByFormatID[code] {
            return mapped
        }
        let trimmed = code.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The four bytes of a format ID as text. Latin-1 so no byte can fail to
    /// decode; the mapping above trims and lowercases whatever comes out.
    private static func fourCC(_ id: AudioFormatID) -> String {
        let bytes = [
            UInt8(truncatingIfNeeded: id >> 24),
            UInt8(truncatingIfNeeded: id >> 16),
            UInt8(truncatingIfNeeded: id >> 8),
            UInt8(truncatingIfNeeded: id),
        ]
        return String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    /// Duration in seconds derived from frame count and sample rate.
    public nonisolated var duration: TimeInterval {
        let rate = self.file.processingFormat.sampleRate
        guard rate > 0 else { return 0 }
        return TimeInterval(self.file.length) / rate
    }

    /// Current read position derived from `framePosition`.
    public var position: TimeInterval {
        get async {
            let rate = self.file.processingFormat.sampleRate
            guard rate > 0 else { return 0 }
            return TimeInterval(self.file.framePosition) / rate
        }
    }

    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioEngineError.fileNotFound(url)
        }
        do {
            self.file = try AVAudioFile(forReading: url)
        } catch {
            // Every open failure used to become `accessDenied`, which
            // `DecoderFactory` rethrows without trying FFmpeg, so the #387
            // fallback could never fire for a format AVFoundation refuses.
            // Only a permissions failure is an access problem; an unsupported
            // type ('typ?'), invalid data ('dta?') or unspecified ('wht?')
            // refusal says AVFoundation cannot decode the file, and that is
            // what the factory offers to FFmpeg (ADR-091 slice 3).
            if Self.isPermissionFailure(error) {
                throw AudioEngineError.accessDenied(url, underlying: error)
            }
            throw AudioEngineError.decoderFailure(codec: "AVFoundation", underlying: error)
        }
        // A file AVAudioFile opens but cannot decode (Opus in MP4 on macOS 26
        // opens with length 0 and fails on the first read) must be refused
        // here, or DecoderFactory's fallback never sees it and the song stops
        // on its first buffer (#523). Read a little and rewind. Length alone
        // is no signal: a FLAC without a STREAMINFO sample count also reports
        // 0 and decodes fine. Permissions were settled at open, so a read
        // error here is a format refusal.
        do {
            try Self.probeRead(self.file)
        } catch {
            throw AudioEngineError.decoderFailure(codec: "AVFoundation", underlying: error)
        }
    }

    /// Frames the open-time probe decodes. Enough for every codec's first
    /// packet, and a negligible cost per open.
    private static let probeFrames: AVAudioFrameCount = 4096

    /// Decodes the first frames and rewinds. An exact-EOF `noErr` (OSStatus 0),
    /// which `AVAudioFile` throws for an empty file, is not a refusal.
    ///
    /// The rewind happens only after a successful read: setting `framePosition`
    /// on a file whose read just failed raises an Objective-C exception with
    /// the same code, which no Swift `catch` can stop (measured on Opus in
    /// MP4). A failed read leaves the position where it was, at zero.
    private static func probeRead(_ file: AVAudioFile) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: probeFrames) else {
            return
        }
        do {
            try file.read(into: buffer)
        } catch {
            if (error as NSError).code != 0 {
                throw error
            }
            return
        }
        file.framePosition = 0
    }

    /// Whether an `AVAudioFile` open error is a permissions failure rather
    /// than a format refusal. Measured on macOS 26: a file with mode 000, or
    /// one inside an unreadable directory, fails with `permErr` (-54) in the
    /// avfaudio domain; AudioToolbox's own `kAudioFilePermissionsError` and
    /// Foundation's no-permission codes are accepted for the same meaning.
    private static func isPermissionFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain:
            return nsError.code == NSFileReadNoPermissionError

        case NSPOSIXErrorDomain:
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)

        default:
            // -54 is the classic `permErr`; AVAudioFile reports it in its own domain.
            return nsError.code == -54 || nsError.code == Int(kAudioFilePermissionsError)
        }
    }

    /// Read frames into `buffer`. Returns 0 at end-of-file.
    public func read(into buffer: AVAudioPCMBuffer) async throws -> AVAudioFrameCount {
        // Guard: nothing left to read. FLACs without a STREAMINFO sample
        // count report length 0 even though the audio decodes fine (the same
        // quirk ReplayGainAnalyzer works around), so zero must not read as
        // instant EOF; fall through and let read(into:) find the real end,
        // which surfaces as the zero-frame/noErr case handled below.
        guard self.file.length == 0 || self.file.framePosition < self.file.length else { return 0 }
        let before = self.file.framePosition
        do {
            try self.file.read(into: buffer)
        } catch {
            // AVAudioFile occasionally throws OSStatus 0 (noErr) at exact EOF —
            // treat that as end-of-stream rather than a real failure.
            let nsError = error as NSError
            if nsError.code == 0 {
                return 0
            }
            throw AudioEngineError.decoderFailure(codec: "AVFoundation", underlying: error)
        }
        // `framePosition` can, in rare EOF/seek-corner cases, fail to advance or
        // even regress.  Clamp the delta to 0 so we never trap on the UInt32
        // bridge below (AVAudioFrameCount init from a negative value crashes).
        let delta = self.file.framePosition - before
        return delta > 0 ? AVAudioFrameCount(delta) : 0
    }

    /// Seek to the nearest sample frame for `time`.
    public func seek(to time: TimeInterval) async throws {
        guard self.duration > 0 else { return }
        if time < 0 || time > self.duration + 0.001 {
            throw AudioEngineError.seekOutOfRange(requested: time, duration: self.duration)
        }
        let rate = self.file.processingFormat.sampleRate
        let frame = AVAudioFramePosition(min(time * rate, Double(self.file.length - 1)))
        self.file.framePosition = max(0, frame)
    }

    /// No-op for AVAudioFile — the OS handles cleanup on dealloc.
    public func close() async {
        // AVAudioFile closes automatically when deallocated.
        self.log.debug("avfoundation.decoder.closed")
    }
}
