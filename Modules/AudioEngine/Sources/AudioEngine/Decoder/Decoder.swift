// @preconcurrency: AVAudioPCMBuffer lacks Sendable; callers own the buffer exclusively.
// Remove once AVFoundation adopts Sendable annotations (FB13119463).
@preconcurrency import AVFoundation
import Foundation

/// A type that can decode an audio file into PCM buffers.
///
/// Conforming types must be safe to call from any concurrency context (`Sendable`),
/// and must be reference types (`AnyObject`) because they own expensive OS resources.
/// All mutating operations are `async` to allow actors to serialise access.
public protocol Decoder: Sendable, AnyObject {
    /// The native sample format produced by this decoder **before** any conversion.
    var sourceFormat: AVAudioFormat { get }

    /// Total duration in seconds. May be approximate for some container formats.
    var duration: TimeInterval { get }

    /// Current read position in seconds.
    var position: TimeInterval { get async }

    /// FFmpeg's short name for the codec the source is stored in ("flac",
    /// "mp3", "eac3", "pcm"), or nil when the decoder cannot say.
    ///
    /// One vocabulary across both routes (ADR-092), so the same file reports
    /// the same name whichever decoder opens it. Never the container: an
    /// `.m4a` carries AAC, ALAC and E-AC-3 alike (#529).
    var codec: String? { get }

    /// Opens `url` for reading. Throws on any I/O or format error.
    init(url: URL) throws

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

/// Default so a decoder that has nothing to say about its codec (the test
/// fakes, any future buffer-backed source) satisfies the requirement without
/// writing anything.
public extension Decoder {
    /// By default a decoder cannot name its codec.
    var codec: String? {
        nil
    }
}
