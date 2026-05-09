// MARK: - AudioEngine + DSP

/// DSP API — apply DSP state, ReplayGain, and playback rate adjustments.
public extension AudioEngine {
    // MARK: - DSP public API

    /// The DSP chain for this engine. Use to apply presets, adjust effects, and set gain.
    var dsp: DSPChain {
        self.graph.dsp
    }

    /// Apply a complete `DSPState` snapshot (EQ, bass boost, crossfeed, width, etc.).
    func applyDSPState(_ state: DSPState) {
        self.graph.dsp.apply(state, presets: self.presets)
    }

    /// Apply the ReplayGain compensation gain in dB.
    func applyReplayGain(db: Double) {
        self.graph.dsp.applyGain(db: db)
    }

    /// Set the playback rate (0.5×–2.0×). Pitch is preserved via the spectral algorithm.
    func setRate(_ rate: Float) {
        self.graph.dsp.setRate(rate)
    }
}
