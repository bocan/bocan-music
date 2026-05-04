import AudioEngine
import Foundation
import Observability
import Playback
import SwiftUI

// MARK: - DSPViewModel

/// Observable view-model for all DSP controls.
///
/// Owns the `DSPState` snapshot and propagates changes to `AudioEngine` immediately.
/// All mutations run on `@MainActor`.
@MainActor
public final class DSPViewModel: ObservableObject {
    // MARK: - Published state

    @Published public var state: DSPState {
        didSet { self.pushToEngine() }
    }

    @Published public var presets: [EQPreset] = []

    /// `true` while ReplayGain analysis is in progress.
    @Published public private(set) var isAnalyzing = false

    // MARK: - Dependencies

    private let engine: AudioEngine
    public let presetStore: PresetStore
    private let queuePlayer: QueuePlayer?
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(engine: AudioEngine, presetStore: PresetStore = PresetStore(), queuePlayer: QueuePlayer? = nil) {
        self.engine = engine
        self.presetStore = presetStore
        self.queuePlayer = queuePlayer
        self.state = DSPState.load()
        self.presets = presetStore.allPresets
        // Apply persisted state immediately.
        Task { await engine.applyDSPState(self.state) }
    }

    // MARK: - Preset actions

    public func selectPreset(_ preset: EQPreset) {
        self.state.eqPresetID = preset.id
        self.state.eqEnabled = true
    }

    public func saveUserPreset(name: String) {
        guard let id = state.eqPresetID,
              let current = presetStore.preset(forID: id) else { return }
        let newPreset = EQPreset(
            id: UUID().uuidString,
            name: name,
            bandGainsDB: current.bandGainsDB,
            isBuiltIn: false,
            outputGainDB: current.outputGainDB
        )
        self.presetStore.save(newPreset)
        self.presets = self.presetStore.allPresets
        self.state.eqPresetID = newPreset.id
    }

    public func deleteUserPreset(id: EQPreset.ID) {
        self.presetStore.delete(id: id)
        self.presets = self.presetStore.allPresets
        if self.state.eqPresetID == id {
            self.state.eqPresetID = BuiltInPresets.flat.id
        }
    }

    /// Updates a single EQ band gain, persisting the change and pushing it to
    /// the audio engine immediately.
    ///
    /// For built-in presets a new user preset named "Custom" is created so the
    /// originals are never mutated.  For user presets the existing entry is
    /// updated in place.
    public func updateBandGain(index: Int, gain: Double) {
        guard let id = self.state.eqPresetID,
              let preset = self.presets.first(where: { $0.id == id }),
              index < preset.bandGainsDB.count else { return }
        var newGains = preset.bandGainsDB
        newGains[index] = gain
        if preset.isBuiltIn {
            let customID = "bocan.custom-edit"
            let custom = EQPreset(
                id: customID,
                name: "Custom",
                bandGainsDB: newGains,
                isBuiltIn: false,
                outputGainDB: preset.outputGainDB
            )
            self.presetStore.save(custom)
            self.presets = self.presetStore.allPresets
            // Assigning eqPresetID triggers state.didSet → pushToEngine().
            self.state.eqPresetID = customID
        } else {
            let updated = EQPreset(
                id: preset.id,
                name: preset.name,
                bandGainsDB: newGains,
                isBuiltIn: false,
                outputGainDB: preset.outputGainDB
            )
            self.presetStore.save(updated)
            self.presets = self.presetStore.allPresets
            // eqPresetID is unchanged so didSet won't fire; push manually.
            self.pushToEngine()
        }
    }

    /// Updates the output gain of the current EQ preset, creating a "Custom" preset
    /// if the current one is built-in (mirrors the `updateBandGain` pattern).
    public func updateOutputGain(_ gain: Double) {
        guard let id = self.state.eqPresetID,
              let preset = self.presets.first(where: { $0.id == id }) else { return }
        if preset.isBuiltIn {
            let customID = "bocan.custom-edit"
            let custom = EQPreset(
                id: customID,
                name: "Custom",
                bandGainsDB: preset.bandGainsDB,
                isBuiltIn: false,
                outputGainDB: gain
            )
            self.presetStore.save(custom)
            self.presets = self.presetStore.allPresets
            self.state.eqPresetID = customID
        } else {
            let updated = EQPreset(
                id: preset.id,
                name: preset.name,
                bandGainsDB: preset.bandGainsDB,
                isBuiltIn: false,
                outputGainDB: gain
            )
            self.presetStore.save(updated)
            self.presets = self.presetStore.allPresets
            self.pushToEngine()
        }
    }

    // MARK: - ReplayGain analysis

    public func analyzeReplayGain(url: URL) async -> ReplayGainResult? {
        self.isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            return try await ReplayGainAnalyzer.analyze(url: url)
        } catch {
            self.log.error("rg.analyze.failed", ["error": String(reflecting: error)])
            return nil
        }
    }

    // MARK: - Private

    private func pushToEngine() {
        self.state.save()
        Task { await self.engine.applyDSPState(self.state) }
        // Forward crossfade config to the playback layer so the slider has effect.
        let config = CrossfadeScheduler.Config(
            durationSeconds: self.state.crossfadeSeconds,
            albumGapless: self.state.crossfadeAlbumGapless
        )
        Task { await self.queuePlayer?.setCrossfadeConfig(config) }
    }
}
