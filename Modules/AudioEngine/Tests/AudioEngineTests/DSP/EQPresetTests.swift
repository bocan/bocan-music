import Foundation
import Testing
@testable import AudioEngine

@Suite("EQPreset")
struct EQPresetTests {
    @Test("isFlat true when all gains are zero")
    func isFlatTrue() {
        let preset = EQPreset(
            id: "test.flat",
            name: "Flat",
            bandGainsDB: Array(repeating: 0, count: 10),
            isBuiltIn: false
        )
        #expect(preset.isFlat)
    }

    @Test("isFlat false when any band gain is non-zero")
    func isFlatFalseBand() {
        var bands = Array(repeating: 0.0, count: 10)
        bands[3] = 1.5
        let preset = EQPreset(
            id: "test.bumped",
            name: "Bumped",
            bandGainsDB: bands,
            isBuiltIn: false
        )
        #expect(!preset.isFlat)
    }

    @Test("isFlat false when output gain is non-zero")
    func isFlatFalseOutput() {
        let preset = EQPreset(
            id: "test.loud",
            name: "Loud",
            bandGainsDB: Array(repeating: 0, count: 10),
            isBuiltIn: false,
            outputGainDB: 2
        )
        #expect(!preset.isFlat)
    }

    @Test("codable round-trip preserves every field")
    func codable() throws {
        let original = EQPreset(
            id: "user.custom",
            name: "Custom",
            bandGainsDB: [-3, -2, -1, 0, 1, 2, 3, 2, 1, 0],
            isBuiltIn: false,
            outputGainDB: -1.5
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EQPreset.self, from: data)
        #expect(decoded == original)
    }

    @Test("equatable distinguishes presets with same ID but different gains")
    func equatableByValue() {
        // swiftlint:disable:next identifier_name
        let a = EQPreset(id: "x", name: "X", bandGainsDB: Array(repeating: 1, count: 10), isBuiltIn: false)
        let b = EQPreset(id: "x", name: "X", bandGainsDB: Array(repeating: 2, count: 10), isBuiltIn: false)
        #expect(a != b)
    }
}
