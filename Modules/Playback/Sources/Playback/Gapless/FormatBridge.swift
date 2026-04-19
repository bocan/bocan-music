@preconcurrency import AVFoundation
import Foundation

// MARK: - FormatBridge

/// Determines whether two audio formats can be stitched on the same `AVAudioPlayerNode`
/// without stopping the engine.
///
/// Gapless compatibility requires:
/// - Same sample rate (AVAudioPlayerNode resamples only at the graph level)
/// - Same channel count
/// Bit depth and interleaving are irrelevant because the engine processes
/// everything as Float32, non-interleaved internally.
public struct FormatBridge: Sendable {
    public init() {}

    /// Returns `true` when `a` and `b` can be scheduled back-to-back on the
    /// same `AVAudioPlayerNode` without an engine restart.
    public func isCompatible(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
    }

    /// Convenience overload for `AudioSourceFormat` (queue-item level format description).
    public func isCompatible(_ a: AudioSourceFormat, _ b: AudioSourceFormat) -> Bool {
        a.isGaplessCompatible(with: b)
    }
}
