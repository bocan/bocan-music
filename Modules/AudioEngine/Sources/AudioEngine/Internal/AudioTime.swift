import AVFoundation
import Foundation

/// Conversions between audio time representations.
public struct AudioTime: Sendable {
    private init() {}

    /// Convert a `TimeInterval` (seconds) to an `AVAudioFramePosition` for `sampleRate`.
    public static func framePosition(for time: TimeInterval, sampleRate: Double) -> AVAudioFramePosition {
        AVAudioFramePosition(time * sampleRate)
    }

    /// Convert an `AVAudioFramePosition` to seconds.
    public static func timeInterval(for frame: AVAudioFramePosition, sampleRate: Double) -> TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(frame) / sampleRate
    }

    /// Current playback position from a `AVAudioPlayerNode`, accounting for any
    /// pending-buffer offset that `AVAudioPlayerNode.currentTime` does not report.
    public static func currentTime(
        from node: AVAudioPlayerNode,
        sampleRate: Double
    ) -> TimeInterval {
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return 0 }
        return self.timeInterval(for: playerTime.sampleTime, sampleRate: sampleRate)
    }
}
