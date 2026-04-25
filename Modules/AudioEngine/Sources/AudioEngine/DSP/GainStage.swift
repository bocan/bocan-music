@preconcurrency import AVFoundation
import Foundation

// MARK: - GainStage

/// Applies a linear gain to the audio stream for ReplayGain.
///
/// Wraps `AVAudioMixerNode`, which provides low-latency volume automation.
/// `setGainDB(_:)` converts dB to linear and writes `outputVolume`, which is
/// thread-safe per AVFoundation documentation.
public final class GainStage: @unchecked Sendable {
    // @unchecked: AVAudioMixerNode lacks Sendable; safety provided by AudioEngine actor.

    /// The underlying mixer node. Connect this in the audio graph.
    let node: AVAudioMixerNode

    public init() {
        self.node = AVAudioMixerNode()
        self.node.outputVolume = 1.0
    }

    /// Apply a gain specified in decibels. Values outside ±40 dB are clamped.
    public func setGainDB(_ db: Double) {
        let clamped = max(-40, min(40, db))
        let linear = Float(pow(10.0, clamped / 20.0))
        self.node.outputVolume = linear
    }

    /// Reset gain to unity (0 dB).
    public func reset() {
        self.node.outputVolume = 1.0
    }

    /// Current gain in dB (read from the node's outputVolume).
    public var gainDB: Double {
        let vol = self.node.outputVolume
        guard vol > 0 else { return -120 }
        return 20.0 * log10(Double(vol))
    }
}
