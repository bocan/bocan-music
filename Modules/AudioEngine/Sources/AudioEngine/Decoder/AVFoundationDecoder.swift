// @preconcurrency: AVAudioPCMBuffer lacks Sendable; callers own the buffer exclusively.
// Remove once AVFoundation adopts Sendable annotations (FB13119463).
@preconcurrency import AVFoundation
import Foundation
import Observability

/// Decodes audio files using `AVAudioFile` — the native macOS decoder.
///
/// Supports WAV (8/16/24/32-bit int, 32/64-bit float), AIFF, FLAC, MP3,
/// AAC and ALAC inside `.m4a` containers. All output is produced in the
/// decoder's `processingFormat` (Float32, non-interleaved) and then up-
/// or down-sampled to the canonical format by `FormatConverter` in `EngineGraph`.
public final class AVFoundationDecoder: Decoder {
    // MARK: - Private state

    private let file: AVAudioFile
    private let log = AppLogger.make(.audio)

    // MARK: - Public interface

    /// The processing format (`Float32`, non-interleaved) used by `AVAudioFile`.
    public var sourceFormat: AVAudioFormat {
        self.file.processingFormat
    }

    /// Duration in seconds derived from frame count and sample rate.
    public var duration: TimeInterval {
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

    public required init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioEngineError.fileNotFound(url)
        }
        do {
            self.file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioEngineError.accessDenied(url, underlying: error)
        }
    }

    /// Read frames into `buffer`. Returns 0 at end-of-file.
    public func read(into buffer: AVAudioPCMBuffer) async throws -> AVAudioFrameCount {
        // Guard: nothing left to read.
        guard self.file.framePosition < self.file.length else { return 0 }
        let before = self.file.framePosition
        do {
            try self.file.read(into: buffer)
        } catch {
            // AVAudioFile occasionally throws OSStatus 0 (noErr) at exact EOF —
            // treat that as end-of-stream rather than a real failure.
            let nsError = error as NSError
            if nsError.code == 0 { return 0 }
            throw AudioEngineError.decoderFailure(codec: "AVFoundation", underlying: error)
        }
        return AVAudioFrameCount(self.file.framePosition - before)
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
