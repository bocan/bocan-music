@preconcurrency import AVFoundation
import Foundation
import Observability

// MARK: - DSPChain

/// Owns, connects, and manages the full DSP signal chain.
///
/// **Chain topology** (all nodes always present; each individually bypassable):
/// ```
/// PlayerNode → GainStage (RG) → EQ → BassBoost → Crossfeed → StereoExpander → Limiter → Mixer
/// ```
///
/// Nodes are attached to the `AVAudioEngine` once at construction.
/// Graph reconnection happens in `reconnect(format:engine:from:to:)` — called by
/// `EngineGraph.start()` when the hardware sample rate is confirmed.
///
/// Thread-safety: all mutations are serialised by the owning `AudioEngine` actor.
public final class DSPChain: @unchecked Sendable {
    // @unchecked: AVFoundation nodes lack Sendable; safety provided by AudioEngine actor.

    // MARK: - Nodes (public for testing)

    public let gainStage: GainStage
    public let eq: EQUnit
    public let bassBoost: BassBoostUnit
    public let crossfeed: CrossfeedUnit
    public let stereoExpander: StereoExpanderUnit
    public let limiter: LimiterUnit

    private let log = AppLogger.make(.audio)

    // MARK: - Graph connection points

    /// First node in the chain; connect the player node output here.
    var inputNode: AVAudioNode {
        self.gainStage.node
    }

    /// Last node in the chain; connect this to the main mixer.
    var outputNode: AVAudioNode {
        self.limiter.node
    }

    // MARK: - Init

    public init() {
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
        // PlayerNode → GainStage → EQ → BassBoost → Crossfeed → StereoExpander → Limiter → Mixer
        engine.connect(playerNode, to: self.gainStage.node, format: format)
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
        engine.disconnectNodeOutput(self.gainStage.node)
        engine.disconnectNodeOutput(self.eq.node)
        engine.disconnectNodeOutput(self.bassBoost.node)
        engine.disconnectNodeOutput(self.crossfeed.node)
        engine.disconnectNodeOutput(self.stereoExpander.node)
        engine.disconnectNodeOutput(self.limiter.node)
    }

    // MARK: - DSP state application

    /// Apply a complete `DSPState` snapshot to the chain.
    public func apply(_ state: DSPState, presets: PresetStore) {
        // EQ
        self.eq.bypass = !state.eqEnabled
        if let id = state.eqPresetID, let preset = presets.preset(forID: id) {
            self.eq.apply(preset: preset)
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

    /// Apply ReplayGain compensation.
    public func applyGain(db: Double) {
        self.gainStage.setGainDB(db)
    }

    /// Reset everything to safe defaults (called on engine stop / new load).
    public func reset() {
        self.gainStage.reset()
        self.eq.reset()
        self.eq.bypass = false
        self.bassBoost.setGainDB(0)
        self.crossfeed.bypass = true
        self.stereoExpander.bypass = true
    }
}
