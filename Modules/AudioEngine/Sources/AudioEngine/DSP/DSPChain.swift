@preconcurrency import AVFoundation
import Foundation
import Observability

// MARK: - DSPChain

/// Owns, connects, and manages the full DSP signal chain.
///
/// **Chain topology** (all nodes always present; each individually bypassable):
/// ```
/// PlayerNode → TimePitch → GainStage (RG) → EQ → BassBoost → Crossfeed → StereoExpander → Limiter → Mixer
/// ```
///
/// `TimePitch` is always first so pitch-corrected speed changes apply before any
/// EQ or dynamics processing.  Its `timePitchAlgorithm` is fixed to `.spectral`
/// at init — changing the algorithm while audio is playing causes a dropout.
///
/// Nodes are attached to the `AVAudioEngine` once at construction.
/// Graph reconnection happens in `reconnect(format:engine:from:to:)` — called by
/// `EngineGraph.start()` when the hardware sample rate is confirmed.
///
/// Thread-safety: all mutations are serialised by the owning `AudioEngine` actor.
public final class DSPChain: @unchecked Sendable {
    // @unchecked: AVFoundation nodes lack Sendable; safety provided by AudioEngine actor.

    // MARK: - Nodes (public for testing)

    /// Pitch-preserving time-stretch node.  Rate is 1.0× by default.
    public let timePitch: AVAudioUnitTimePitch
    public let gainStage: GainStage
    public let eq: EQUnit
    public let bassBoost: BassBoostUnit
    public let crossfeed: CrossfeedUnit
    public let stereoExpander: StereoExpanderUnit
    public let limiter: LimiterUnit

    private let log = AppLogger.make(.audio)

    /// In-flight gain ramp task — cancelled and replaced on each preset change.
    private var eqRampTask: Task<Void, Never>?

    // MARK: - Graph connection points

    /// First node in the chain; connect the player node output here.
    var inputNode: AVAudioNode {
        self.timePitch
    }

    /// Last node in the chain; connect this to the main mixer.
    var outputNode: AVAudioNode {
        self.limiter.node
    }

    // MARK: - Init

    public init() {
        self.timePitch = AVAudioUnitTimePitch()
        // AVAudioUnitTimePitch always uses a high-quality spectral (phase-vocoder)
        // algorithm internally — no algorithm property to set.
        self.gainStage = GainStage()
        self.eq = EQUnit()
        self.bassBoost = BassBoostUnit()
        self.crossfeed = CrossfeedUnit()
        self.stereoExpander = StereoExpanderUnit()
        self.limiter = LimiterUnit()
    }

    // MARK: - Engine integration

    /// Attach all nodes to the engine. Call once on construction.
    func attach(to engine: AVAudioEngine) {
        engine.attach(self.timePitch)
        engine.attach(self.gainStage.node)
        engine.attach(self.eq.node)
        engine.attach(self.bassBoost.node)
        engine.attach(self.crossfeed.node)
        engine.attach(self.stereoExpander.node)
        engine.attach(self.limiter.node)
    }

    /// Connect the internal chain with the given format.
    /// `from` is the player node output; `to` is the main mixer input.
    func connect(
        format: AVAudioFormat?,
        engine: AVAudioEngine,
        from playerNode: AVAudioPlayerNode,
        to mixer: AVAudioMixerNode
    ) {
        // PlayerNode → TimePitch → GainStage → EQ → BassBoost → Crossfeed → StereoExpander → Limiter → Mixer
        engine.connect(playerNode, to: self.timePitch, format: format)
        engine.connect(self.timePitch, to: self.gainStage.node, format: format)
        engine.connect(self.gainStage.node, to: self.eq.node, format: format)
        engine.connect(self.eq.node, to: self.bassBoost.node, format: format)
        engine.connect(self.bassBoost.node, to: self.crossfeed.node, format: format)
        engine.connect(self.crossfeed.node, to: self.stereoExpander.node, format: format)
        engine.connect(self.stereoExpander.node, to: self.limiter.node, format: format)
        engine.connect(self.limiter.node, to: mixer, format: format)
        self.log.debug("dsp.chain.connected", ["sampleRate": format?.sampleRate ?? 0])
    }

    /// Disconnect all internal and boundary connections.
    func disconnect(engine: AVAudioEngine, playerNode: AVAudioPlayerNode) {
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(self.timePitch)
        engine.disconnectNodeOutput(self.gainStage.node)
        engine.disconnectNodeOutput(self.eq.node)
        engine.disconnectNodeOutput(self.bassBoost.node)
        engine.disconnectNodeOutput(self.crossfeed.node)
        engine.disconnectNodeOutput(self.stereoExpander.node)
        engine.disconnectNodeOutput(self.limiter.node)
    }

    /// Set the playback rate (0.5×–2.0×) with pitch correction.
    public func setRate(_ rate: Float) {
        self.timePitch.rate = rate.clamped(to: 0.5 ... 2.0)
        self.log.debug("dsp.rate.set", ["rate": rate])
    }

    // MARK: - DSP state application

    /// Apply a complete `DSPState` snapshot to the chain.
    public func apply(_ state: DSPState, presets: PresetStore) {
        // EQ — ramp gains when the EQ is active before *and* after the change to
        // avoid the pop caused by stepping IIR biquad coefficients mid-stream.
        let eqWasActive = !self.eq.bypass
        self.eq.bypass = !state.eqEnabled
        if let id = state.eqPresetID, let preset = presets.preset(forID: id) {
            if eqWasActive, state.eqEnabled {
                self.rampEQ(to: preset)
            } else {
                // Instant apply is safe when the EQ was or will be bypassed.
                self.eq.apply(preset: preset)
            }
        }

        // Bass boost
        self.bassBoost.setGainDB(state.bassBoostDB)

        // Crossfeed
        self.crossfeed.setAmount(state.crossfeedAmount)
        self.crossfeed.bypass = state.crossfeedAmount < 1e-4

        // Stereo expander
        self.stereoExpander.setWidth(state.stereoWidth)
        // At unity width, bypass to save a tiny bit of CPU and guarantee identity output.
        self.stereoExpander.bypass = abs(state.stereoWidth - 1.0) < 1e-4

        self.log.debug("dsp.state.applied", [
            "eq": state.eqEnabled,
            "preset": state.eqPresetID ?? "custom",
            "bass": state.bassBoostDB,
            "crossfeed": state.crossfeedAmount,
            "width": state.stereoWidth,
        ])
    }

    /// Interpolate EQ band gains from their current values to the target preset over ~60 ms.
    ///
    /// This prevents the audible pop that occurs when IIR biquad coefficients change
    /// instantaneously mid-stream (the filter's delay-line state doesn't match the new
    /// coefficients, producing a transient).  12 steps × 5 ms = 60 ms total — below the
    /// threshold of audible latency and well above typical render-cycle durations.
    private func rampEQ(to target: EQPreset) {
        self.eqRampTask?.cancel()
        let startGains = self.eq.node.bands.map { Double($0.gain) }
        let startGlobal = Double(self.eq.node.globalGain)
        let targetGains = target.bandGainsDB
        let targetGlobal = target.outputGainDB
        let steps = 12
        self.eqRampTask = Task { [weak self] in
            for step in 1 ... steps {
                guard !Task.isCancelled, let self else { return }
                let t = Double(step) / Double(steps)
                // Ease-in-out so the ramp feels smooth rather than linear.
                let ease = t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t
                for i in 0 ..< min(self.eq.node.bands.count, targetGains.count) {
                    self.eq.node.bands[i].gain = Float(startGains[i] + (targetGains[i] - startGains[i]) * ease)
                }
                self.eq.node.globalGain = Float(startGlobal + (targetGlobal - startGlobal) * ease)
                try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
            }
        }
    }

    /// Apply ReplayGain compensation.
    public func applyGain(db: Double) {
        self.gainStage.setGainDB(db)
    }

    /// Reset everything to safe defaults (called on engine stop / new load).
    public func reset() {
        self.eqRampTask?.cancel()
        self.eqRampTask = nil
        self.gainStage.reset()
        self.eq.reset()
        self.eq.bypass = false
        self.bassBoost.setGainDB(0)
        self.crossfeed.bypass = true
        self.stereoExpander.bypass = true
    }
}

// MARK: - Comparable clamp helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
