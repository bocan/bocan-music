import Foundation
import Testing
@testable import AudioEngine

// MARK: - PresetStoreTests

@Suite("PresetStore")
struct PresetStoreTests {
    /// Use an isolated in-memory UserDefaults suite for each test.
    private func makeStore() -> PresetStore {
        let suite = UUID().uuidString
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suite)!
        return PresetStore(defaults: defaults)
    }

    @Test("Built-in presets are always present")
    func builtInsPresent() {
        let store = self.makeStore()
        let all = store.allPresets
        #expect(all.contains { $0.id == "bocan.flat" })
        #expect(all.contains { $0.id == "bocan.rock" })
        #expect(all.count == BuiltInPresets.all.count)
    }

    @Test("Saving a user preset appends it after built-ins")
    func saveUserPreset() {
        let store = self.makeStore()
        let preset = EQPreset(
            id: UUID().uuidString,
            name: "My Preset",
            bandGainsDB: Array(repeating: 1, count: 10),
            isBuiltIn: false
        )
        store.save(preset)
        let all = store.allPresets
        #expect(all.count == BuiltInPresets.all.count + 1)
        #expect(store.userPresets.count == 1)
        #expect(store.userPresets.first?.name == "My Preset")
    }

    @Test("Saving a preset with same ID updates it")
    func updatePreset() {
        let store = self.makeStore()
        let id = UUID().uuidString
        let v1 = EQPreset(id: id, name: "V1", bandGainsDB: Array(repeating: 0, count: 10), isBuiltIn: false)
        let v2 = EQPreset(id: id, name: "V2", bandGainsDB: Array(repeating: 2, count: 10), isBuiltIn: false)
        store.save(v1)
        store.save(v2)
        #expect(store.userPresets.count == 1)
        #expect(store.userPresets.first?.name == "V2")
    }

    @Test("Deleting a user preset removes it")
    func deletePreset() {
        let store = self.makeStore()
        let id = UUID().uuidString
        let preset = EQPreset(id: id, name: "Temp", bandGainsDB: Array(repeating: 0, count: 10), isBuiltIn: false)
        store.save(preset)
        store.delete(id: id)
        #expect(store.userPresets.isEmpty)
    }

    @Test("preset(forID:) finds built-in")
    func findBuiltIn() {
        let store = self.makeStore()
        let found = store.preset(forID: "bocan.jazz")
        #expect(found?.name == "Jazz")
    }

    @Test("preset(forID:) returns nil for unknown ID")
    func unknownIDReturnsNil() {
        let store = self.makeStore()
        #expect(store.preset(forID: "no.such.preset") == nil)
    }

    @Test("Saving a built-in preset is a no-op")
    func saveBuiltInIsNoop() {
        let store = self.makeStore()
        store.save(BuiltInPresets.rock)
        #expect(store.userPresets.isEmpty)
    }

    @Test("Preset load/save round-trips via UserDefaults")
    func roundTrip() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let id = UUID().uuidString
        let gains = (0 ..< 10).map { Double($0) - 5 }
        let preset = EQPreset(id: id, name: "RT", bandGainsDB: gains, isBuiltIn: false, outputGainDB: 1.5)

        let store1 = PresetStore(defaults: defaults)
        store1.save(preset)

        // Reload from the same defaults
        let store2 = PresetStore(defaults: defaults)
        let loaded = store2.userPresets.first
        #expect(loaded?.id == id)
        #expect(loaded?.name == "RT")
        #expect(loaded?.outputGainDB == 1.5)
        #expect(loaded?.bandGainsDB == gains)
    }
}
