// @preconcurrency: AVAudioPCMBuffer lacks Sendable; callers own the buffer exclusively.
// TODO: Remove once AVFoundation adopts Sendable annotations.
@preconcurrency import AVFoundation
import Foundation

/// A type that can decode an audio file into PCM buffers.
///
/// Conforming types must be safe to call from any concurrency context (`Sendable`),
/// and must be reference types (`AnyObject`) because they own expensive OS resources.
/// All mutating operations are `async` to allow actors to serialise access.
public protocol Decoder: Sendable, AnyObject {
    /// Opens `url` for reading. The caller must have already granted security-scoped
    /// access where required (via `SecurityScope` — Phase 3). Throws on any I/O or
    /// format error.
    init(url: URL) throws

    /// The native sample format produced by this decoder **before** any conversion.
    var sourceFormat: AVAudioFormat { get }

    /// Total duration in seconds. May be approximate for some container formats.
    var duration: TimeInterval { get }

    /// Current read position in seconds.
    var position: TimeInterval { get async }

    /// Fill `buffer` with up to `buffer.frameCapacity` decoded frames.
    ///
    /// - Returns: Number of frames actually written. Returns `0` at end-of-stream.
    /// - Throws: `AudioEngineError.decoderFailure` on a decode error.
    ///
    /// Callers **must** distinguish between `0` (EOF) and a thrown error.
    func read(into buffer: AVAudioPCMBuffer) async throws -> AVAudioFrameCount

    /// Seek to approximately `time` seconds. Precision is codec-dependent.
    /// Throws `AudioEngineError.seekOutOfRange` if out of bounds.
    func seek(to time: TimeInterval) async throws

    /// Release all OS resources. After this call the decoder must not be used.
    func close() async
}
