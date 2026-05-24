import Foundation
import Testing
@testable import AudioEngine

@Suite("DSPState")
struct DSPStateTests {
    @Test("default values match documented defaults")
    func defaults() {
        let state = DSPState()
        #expect(state.eqEnabled == true)
        #expect(state.eqPresetID == BuiltInPresets.flat.id)
        #expect(state.bassBoostDB == 0)
        #expect(state.crossfeedAmount == 0)
        #expect(state.stereoWidth == 1.0)
        #expect(state.replayGainMode == .track)
        #expect(state.preAmpDB == 0)
        #expect(state.crossfadeSeconds == 0)
        #expect(state.crossfadeAlbumGapless == true)
    }

    @Test("codable round-trip preserves all fields")
    func codable() throws {
        var state = DSPState()
        state.eqEnabled = false
        state.eqPresetID = "user.custom"
        state.bassBoostDB = 6
        state.crossfeedAmount = 0.4
        state.stereoWidth = 1.5
        state.replayGainMode = .album
        state.preAmpDB = -3
        state.crossfadeSeconds = 8
        state.crossfadeAlbumGapless = false

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DSPState.self, from: data)
        #expect(decoded == state)
    }

    @Test("save then load via UserDefaults returns the same state")
    func userDefaultsRoundTrip() throws {
        let suite = "io.cloudcauldron.bocan.test.dspstate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var state = DSPState()
        state.bassBoostDB = 9
        state.crossfeedAmount = 0.7
        state.crossfadeSeconds = 4
        state.save(to: defaults)

        let loaded = DSPState.load(from: defaults)
        #expect(loaded == state)
    }

    @Test("load returns defaults when nothing is stored")
    func loadFromEmptyDefaults() throws {
        let suite = "io.cloudcauldron.bocan.test.dspstate.empty.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let loaded = DSPState.load(from: defaults)
        #expect(loaded == DSPState())
    }

    @Test("load returns defaults when stored blob is corrupt")
    func loadFromCorruptDefaults() throws {
        let suite = "io.cloudcauldron.bocan.test.dspstate.corrupt.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Data([0xFF, 0x00, 0xAB]), forKey: "io.cloudcauldron.bocan.dspState")
        let loaded = DSPState.load(from: defaults)
        #expect(loaded == DSPState())
    }
}
