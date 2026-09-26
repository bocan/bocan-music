// MARK: - AudioEngine + DSP

/// DSP API — apply DSP state and playback rate adjustments.
public extension AudioEngine {
    // MARK: - DSP public API

    /// The DSP chain for this engine. Use to apply presets and adjust effects.
    var dsp: DSPChain {
        self.graph.dsp
    }

    /// Apply a complete `DSPState` snapshot (EQ, bass boost, crossfeed, width,
    /// ReplayGain mode and pre-amp, etc.).
    func applyDSPState(_ state: DSPState) async {
        self.graph.dsp.apply(state, presets: self.presets)
        await self.applyReplayGainSettings(from: state)
    }

    /// Set the playback rate (0.5×–2.0×). Pitch is preserved via the spectral algorithm.
    func setRate(_ rate: Float) {
        self.graph.dsp.setRate(rate)
    }
}
