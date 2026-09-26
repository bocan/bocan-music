import AudioEngine
import Foundation
import Playback
import Testing
@testable import Persistence
@testable import UI

// MARK: - DSPCrossfadeForwardingTests

/// Regression (ADR-095): the saved crossfade setting reached the player only
/// when a DSP control changed, so after every launch crossfade stayed off
/// until the slider was moved. The view model now forwards it at init too.
@Suite("DSPViewModel crossfade forwarding")
@MainActor
struct DSPCrossfadeForwardingTests {
    @Test("the saved crossfade setting reaches the player at launch, with no control touched")
    func forwardsSavedSettingAtInit() async throws {
        let suite = "DSPCrossfadeForwardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved = DSPState()
        saved.crossfadeSeconds = 6
        saved.crossfadeAlbumGapless = false
        saved.save(to: defaults)

        let player = try await QueuePlayer(engine: AudioEngine(), database: Database(location: .inMemory))
        let vm = DSPViewModel(engine: AudioEngine(), queuePlayer: player, defaults: defaults)

        // The forward is a fire-and-forget task; give it a bounded wait.
        let deadline = ContinuousClock.now + .seconds(5)
        var config = await player.crossfadeConfig()
        while config.durationSeconds != 6, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            config = await player.crossfadeConfig()
        }
        #expect(config.durationSeconds == 6)
        #expect(config.albumGapless == false)
        withExtendedLifetime(vm) {}
    }
}
