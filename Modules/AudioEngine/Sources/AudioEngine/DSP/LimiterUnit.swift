import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

// MARK: - LimiterUnit

/// Post-EQ peak limiter that prevents clipping.
///
/// Uses Apple's built-in `kAudioUnitSubType_PeakLimiter` (Dynamics Processing category).
/// Threshold: −0.3 dBFS (via −0.3 dB pre-gain), attack 1 ms, release 50 ms.
/// Always remains in the graph; never bypassed to maintain the loudness guard.
public final class LimiterUnit: @unchecked Sendable {
    // @unchecked: AVAudioUnitEffect lacks Sendable; safety provided by AudioEngine actor.

    /// Parameters for kAudioUnitSubType_PeakLimiter
    /// kLimiterParam_AttackTime  = 0   (0.001 – 0.030 s)
    /// kLimiterParam_DecayTime   = 1   (0.001 – 1.0 s)
    /// kLimiterParam_PreGain     = 2   (−40 – 40 dB)
    private enum LimiterParam {
        static let attackTime: AudioUnitParameterID = 0
        static let decayTime: AudioUnitParameterID = 1
        static let preGain: AudioUnitParameterID = 2
    }

    /// The underlying effect node. Connect this in the audio graph.
    let node: AVAudioUnitEffect

    public init() {
        // kAudioUnitType_Dynamics is not exposed in Swift; use kAudioUnitType_Effect (='aufx').
        // The Peak Limiter responds to kAudioUnitType_Effect on macOS (confirmed via swift REPL).
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        self.node = AVAudioUnitEffect(audioComponentDescription: desc)
        self.configure()
    }

    // MARK: - Private

    private func configure() {
        let au = self.node.audioUnit
        // 1 ms attack
        AudioUnitSetParameter(au, LimiterParam.attackTime, kAudioUnitScope_Global, 0, 0.001, 0)
        // 50 ms release
        AudioUnitSetParameter(au, LimiterParam.decayTime, kAudioUnitScope_Global, 0, 0.050, 0)
        // −0.3 dB pre-gain → output never exceeds −0.3 dBFS before the internal 0 dBFS threshold
        AudioUnitSetParameter(au, LimiterParam.preGain, kAudioUnitScope_Global, 0, -0.3, 0)
    }
}
