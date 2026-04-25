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
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(engine: AudioEngine, presetStore: PresetStore = PresetStore()) {
        self.engine = engine
        self.presetStore = presetStore
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
    }
}
