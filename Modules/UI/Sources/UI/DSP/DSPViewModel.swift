import AudioEngine
import Foundation
import Observability
import Persistence
import Playback
import SwiftUI

// MARK: - EQScope

/// Which scope the EQ preset picker is currently targeting.
public enum EQScope: String, CaseIterable, Sendable {
    case global = "Global"
    case album = "This Album"
    case track = "This Track"
}

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

    /// Which scope the EQ picker targets (Global / This Album / This Track).
    @Published public var eqScope: EQScope = .global

    /// The `Track.id` of the currently-playing track, updated automatically.
    @Published public private(set) var currentTrackID: Int64?

    /// The `Album.id` of the currently-playing track's album, updated automatically.
    @Published public private(set) var currentAlbumID: Int64?

    /// Whether there is a scoped (track or album) EQ assignment active for the current track.
    @Published public private(set) var hasScopedPreset = false

    // MARK: - Dependencies

    private let engine: AudioEngine
    public let presetStore: PresetStore
    private let queuePlayer: QueuePlayer?
    private let assignmentRepo: DSPAssignmentRepository?
    private let log = AppLogger.make(.ui)

    /// Transient override — set from a scoped assignment on track load.
    /// Not persisted; cleared when the user explicitly picks a preset.
    private var eqOverridePresetID: String?

    // MARK: - Init

    public init(
        engine: AudioEngine,
        presetStore: PresetStore = PresetStore(),
        queuePlayer: QueuePlayer? = nil,
        assignmentRepo: DSPAssignmentRepository? = nil
    ) {
        self.engine = engine
        self.presetStore = presetStore
        self.queuePlayer = queuePlayer
        self.assignmentRepo = assignmentRepo
        self.state = DSPState.load()
        self.presets = presetStore.allPresets
        // Apply persisted state immediately.
        Task { await engine.applyDSPState(self.state) }
        // Observe track loads to resolve scoped EQ assignments.
        if let qp = queuePlayer {
            Task { @MainActor [weak self] in
                for await change in qp.trackIDChanges {
                    self?.handleTrackIDChange(trackID: change.trackID, albumID: change.albumID)
                }
            }
        }
    }

    // MARK: - Preset actions

    public func selectPreset(_ preset: EQPreset) {
        // Selecting a preset explicitly clears any transient scoped override.
        self.eqOverridePresetID = nil
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

    // MARK: - EQ scope assignment

    /// Saves the currently-selected EQ preset as an override for the current scope.
    ///
    /// Does nothing when scope is `.global` (global preset is already persisted via UserDefaults)
    /// or when there is no current track/album for the requested scope.
    public func saveCurrentScopePreset() async {
        guard let presetID = self.state.eqPresetID else { return }
        do {
            switch self.eqScope {
            case .global:
                break

            case .track:
                guard let tid = self.currentTrackID else { return }
                try await self.assignmentRepo?.setTrackPreset(trackID: tid, presetID: presetID)
                self.hasScopedPreset = true
                self.log.debug("dsp.scope.save.track", ["trackID": tid, "presetID": presetID])

            case .album:
                guard let aid = self.currentAlbumID else { return }
                try await self.assignmentRepo?.setAlbumPreset(albumID: aid, presetID: presetID)
                self.hasScopedPreset = true
                self.log.debug("dsp.scope.save.album", ["albumID": aid, "presetID": presetID])
            }
        } catch {
            self.log.error("dsp.scope.save.failed", ["error": String(reflecting: error)])
        }
    }

    /// Clears the scoped EQ override for the current scope.
    public func clearCurrentScopePreset() async {
        do {
            switch self.eqScope {
            case .global:
                break

            case .track:
                guard let tid = self.currentTrackID else { return }
                try await self.assignmentRepo?.clearTrackPreset(trackID: tid)
                self.eqOverridePresetID = nil
                self.hasScopedPreset = false
                self.log.debug("dsp.scope.clear.track", ["trackID": tid])

            case .album:
                guard let aid = self.currentAlbumID else { return }
                try await self.assignmentRepo?.clearAlbumPreset(albumID: aid)
                self.eqOverridePresetID = nil
                self.hasScopedPreset = false
                self.log.debug("dsp.scope.clear.album", ["albumID": aid])
            }
        } catch {
            self.log.error("dsp.scope.clear.failed", ["error": String(reflecting: error)])
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
        // Use the scoped override if active, otherwise the global preset.
        var stateToApply = self.state
        if let override = self.eqOverridePresetID {
            stateToApply.eqPresetID = override
        }
        Task { await self.engine.applyDSPState(stateToApply) }
        // Forward crossfade config to the playback layer so the slider has effect.
        let config = CrossfadeScheduler.Config(
            durationSeconds: self.state.crossfadeSeconds,
            albumGapless: self.state.crossfadeAlbumGapless
        )
        Task { await self.queuePlayer?.setCrossfadeConfig(config) }
    }

    /// Called from the `trackIDChanges` observation Task whenever a new track loads.
    private func handleTrackIDChange(trackID: Int64, albumID: Int64?) {
        self.currentTrackID = trackID >= 0 ? trackID : nil
        self.currentAlbumID = albumID
        // Reset scope to global when playback stops.
        if trackID < 0 {
            self.eqOverridePresetID = nil
            self.hasScopedPreset = false
            return
        }
        guard let repo = self.assignmentRepo else { return }
        Task { [weak self] in
            guard let self else { return }
            let resolved = try? await repo.resolvePresetID(trackID: trackID, albumID: albumID)
            self.eqOverridePresetID = resolved
            self.hasScopedPreset = resolved != nil
            if resolved != nil {
                // Re-push engine state so the override takes effect immediately.
                self.pushToEngine()
            }
            self.log.debug(
                "dsp.scope.resolved",
                ["trackID": trackID, "preset": resolved ?? "global"]
            )
        }
    }
}
