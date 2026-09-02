import AudioEngine
import Foundation
import Persistence
import Testing
@testable import UI

/// The quality picker's view-model surface (ADR-088): transcode state,
/// per-rung estimates, and the preparing-progress watcher.
@MainActor
@Suite("PhoneSyncViewModel transcode")
struct PhoneSyncTranscodeViewModelTests {
    @Test("load hydrates the transcode state and the estimate follows the rung")
    func loadHydrates() async {
        let control = FakePhoneSyncControl()
        control.transcode = PhoneSyncTranscodeState(preset: .opus128, keepArtifacts: true)
        control.rungEstimates = [
            TranscodePreset?.none: PhoneSyncSizeEstimate(bytes: 1000, trackCount: 2, episodeCount: 0),
            .opus128: PhoneSyncSizeEstimate(bytes: 300, trackCount: 2, episodeCount: 0),
        ]
        let vm = PhoneSyncViewModel(control: control)
        await vm.load()
        #expect(vm.transcode.preset == .opus128)
        #expect(vm.transcode.keepArtifacts == true)
        #expect(vm.sizeEstimate.bytes == 300, "the estimate row follows the active rung")
        #expect(vm.rungEstimates.count == 2)
    }

    @Test("choosing a rung persists it and the estimate follows")
    func choosingRungPersists() async {
        let control = FakePhoneSyncControl()
        control.rungEstimates = [
            TranscodePreset?.none: PhoneSyncSizeEstimate(bytes: 1000, trackCount: 2, episodeCount: 0),
            .mp3320: PhoneSyncSizeEstimate(bytes: 600, trackCount: 2, episodeCount: 0),
        ]
        let vm = PhoneSyncViewModel(control: control)
        await vm.load()
        #expect(vm.sizeEstimate.bytes == 1000)

        await vm.setTranscodePreset(.mp3320)
        #expect(control.savedTranscodeStates.map(\.preset) == [.mp3320])
        #expect(vm.sizeEstimate.bytes == 600)

        await vm.setKeepArtifacts(true)
        #expect(control.savedTranscodeStates.count == 2)
        #expect(control.transcode.keepArtifacts == true)
        // The profile itself was never re-saved by transcode edits.
        #expect(control.savedProfiles.isEmpty)
    }

    @Test("the progress watcher assigns the stream's emissions")
    func progressWatcher() async {
        let control = FakePhoneSyncControl()
        control.transcodeProgress = PhoneSyncTranscodeProgress(prepared: 12, total: 40)
        let vm = PhoneSyncViewModel(control: control)
        await vm.watchTranscodeProgress()
        #expect(vm.transcodeProgress == PhoneSyncTranscodeProgress(prepared: 12, total: 40))
        #expect(vm.transcodeProgress?.isComplete == false)
        #expect(PhoneSyncTranscodeProgress(prepared: 40, total: 40).isComplete)
    }

    @Test("the quality controls carry their identifiers and localized copy")
    func viewConventions() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Settings/PhoneSyncSettingsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("A11y.SettingsIDs.phoneSyncQuality"))
        #expect(source.contains("A11y.SettingsIDs.phoneSyncKeepArtifacts"))
        #expect(source.contains("Preparing for sync"))
        #expect(source.contains("Keep prepared copies for faster re-syncs"))
    }
}
