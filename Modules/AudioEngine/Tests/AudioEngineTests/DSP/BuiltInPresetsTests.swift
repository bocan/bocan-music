import Foundation
import Testing
@testable import AudioEngine

// MARK: - BuiltInPresetsTests

@Suite("BuiltInPresets")
struct BuiltInPresetsTests {
    @Test("All built-in presets have exactly 10 bands")
    func tenBands() {
        for preset in BuiltInPresets.all {
            #expect(preset.bandGainsDB.count == 10, "Preset '\(preset.name)' has wrong band count")
        }
    }

    @Test("Flat preset has all zero gains")
    func flatIsZero() {
        #expect(BuiltInPresets.flat.bandGainsDB.allSatisfy { $0 == 0 })
        #expect(BuiltInPresets.flat.outputGainDB == 0)
    }

    @Test("All built-in presets have unique IDs")
    func uniqueIDs() {
        let ids = BuiltInPresets.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("All built-in presets are marked isBuiltIn = true")
    func areBuiltIn() {
        // swiftformat:disable:next preferKeyPath — key path form triggers a rethrows compile error here
        #expect(BuiltInPresets.all.allSatisfy { $0.isBuiltIn })
    }

    @Test("Exactly 10 built-in presets")
    func count() {
        #expect(BuiltInPresets.all.count == 10)
    }

    @Test("Band gains are within ±12 dB range")
    func gainsInRange() {
        for preset in BuiltInPresets.all {
            for gain in preset.bandGainsDB {
                #expect(gain >= -12, "Preset '\(preset.name)' has gain below −12 dB")
                #expect(gain <= 12, "Preset '\(preset.name)' has gain above +12 dB")
            }
        }
    }

    @Test("EQPreset is Codable (round-trips through JSON)")
    func codable() throws {
        let preset = BuiltInPresets.jazz
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(EQPreset.self, from: data)
        #expect(decoded.id == preset.id)
        #expect(decoded.name == preset.name)
        #expect(decoded.bandGainsDB == preset.bandGainsDB)
        #expect(decoded.outputGainDB == preset.outputGainDB)
        #expect(decoded.isBuiltIn == preset.isBuiltIn)
    }
}
