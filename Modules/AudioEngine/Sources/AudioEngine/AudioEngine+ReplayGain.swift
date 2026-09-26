import Foundation

// MARK: - ReplayGainSettings

/// The ReplayGain part of `DSPState`: what the user chose in Settings.
struct ReplayGainSettings: Equatable {
    var mode = DSPState().replayGainMode
    var preAmpDB = DSPState().preAmpDB
}

// MARK: - AudioEngine + ReplayGain

/// ReplayGain at playback (#573). Each track's gain is applied to its own
/// samples inside the buffer pump (`PumpSource.gain`), never on a node in
/// the graph: during a crossfade two tracks share one node, and a gain there
/// would give one track the other's level (ADR-095, Gotchas).
///
/// The engine keeps each loaded track's ReplayGain facts beside its decoder
/// (`currentReplayGain`, `pendingNextReplayGain`, `PendingCrossfade`), so a
/// change of mode or pre-amp reapplies to them at once, and the facts move
/// with the decoder at every transition.
extension AudioEngine {
    /// The linear gain for `track` under the current settings.
    func replayGainLinear(for track: TrackReplayGain?) -> Float {
        GainApplication.linearGain(
            for: track,
            mode: self.replayGainSettings.mode,
            preAmpDB: self.replayGainSettings.preAmpDB
        )
    }

    /// Take the mode and pre-amp from `state`, and when they changed,
    /// reapply the gain of every track the engine holds.
    func applyReplayGainSettings(from state: DSPState) async {
        let settings = ReplayGainSettings(mode: state.replayGainMode, preAmpDB: state.preAmpDB)
        guard settings != self.replayGainSettings else { return }
        self.replayGainSettings = settings
        self.log.debug("replaygain.settings", ["mode": settings.mode.rawValue, "preAmpDB": settings.preAmpDB])

        // Everything is read before the first await: the gains are matched
        // to sources by decoder, so a transition during the awaits cannot
        // put one track's gain on another.
        var updates: [GainUpdate] = []
        if let pump = self.pump {
            if let decoder = self.decoder {
                updates.append(GainUpdate(pump: pump, decoder: decoder, gain: self.replayGainLinear(for: self.currentReplayGain)))
            }
            if let pending = self.pendingCrossfade {
                updates.append(GainUpdate(pump: pump, decoder: pending.decoder, gain: self.replayGainLinear(for: pending.replayGain)))
            }
        }
        if let next = self.pendingNextPump, let decoder = self.pendingNextDecoder {
            updates.append(GainUpdate(pump: next, decoder: decoder, gain: self.replayGainLinear(for: self.pendingNextReplayGain)))
        }
        for update in updates {
            await update.pump.setGain(update.gain, forDecoder: update.decoder)
        }
    }
}

/// One track's new gain, and the pump that reads it.
private struct GainUpdate {
    let pump: BufferPump
    let decoder: any Decoder
    let gain: Float
}
