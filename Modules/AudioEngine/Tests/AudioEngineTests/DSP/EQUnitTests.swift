import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - EQUnitTests

@Suite("EQUnit")
struct EQUnitTests {
    @Test("EQUnit initialises with 10 bands")
    func bandCount() {
        let eq = EQUnit()
        #expect(eq.node.bands.count == 10)
    }

    @Test("All bands default to 0 dB gain")
    func defaultGains() {
        let eq = EQUnit()
        for band in eq.node.bands {
            #expect(band.gain == 0)
        }
        #expect(eq.node.globalGain == 0)
    }

    @Test("First band is lowShelf, last is highShelf, rest are parametric")
    func filterTypes() {
        let eq = EQUnit()
        #expect(eq.node.bands[0].filterType == .lowShelf)
        #expect(eq.node.bands[9].filterType == .highShelf)
        for i in 1 ..< 9 {
            #expect(eq.node.bands[i].filterType == .parametric)
        }
    }

    @Test("apply(preset:) writes all band gains")
    func applyPreset() {
        let eq = EQUnit()
        eq.apply(preset: BuiltInPresets.rock)
        let expected = BuiltInPresets.rock.bandGainsDB
        for (i, db) in expected.enumerated() {
            #expect(abs(Double(eq.node.bands[i].gain) - db) < 0.01, "Band \(i) mismatch")
        }
    }

    @Test("reset() clears all gains")
    func resetClearsGains() {
        let eq = EQUnit()
        eq.apply(preset: BuiltInPresets.rock)
        eq.reset()
        for band in eq.node.bands {
            #expect(band.gain == 0)
        }
        #expect(eq.node.globalGain == 0)
    }

    @Test("bypass toggles correctly")
    func bypassToggle() {
        let eq = EQUnit()
        #expect(!eq.bypass)
        eq.bypass = true
        #expect(eq.bypass)
        eq.bypass = false
        #expect(!eq.bypass)
    }

    @Test("Band frequencies match ISO 1/3-octave values")
    func bandFrequencies() {
        let eq = EQUnit()
        let expected = EQUnit.isoFrequencies
        for (i, band) in eq.node.bands.enumerated() {
            #expect(abs(band.frequency - expected[i]) < 0.1, "Band \(i) frequency mismatch")
        }
    }
}

// MARK: - BassBoostUnitTests

@Suite("BassBoostUnit")
struct BassBoostUnitTests {
    @Test("Starts bypassed (off)")
    func startsOff() {
        let bb = BassBoostUnit()
        #expect(bb.node.bypass)
    }

    @Test("setGainDB enables when > 0")
    func setGainEnables() {
        let bb = BassBoostUnit()
        bb.setGainDB(6)
        #expect(!bb.node.bypass)
        #expect(abs(bb.gainDB - 6.0) < 0.01)
    }

    @Test("setGainDB(0) disables bass boost (bypasses node)")
    func setGainZeroDisables() {
        let bb = BassBoostUnit()
        bb.setGainDB(6)
        bb.setGainDB(0)
        #expect(bb.node.bypass)
    }

    @Test("Gain is clamped to 0–12 dB range")
    func gainClamped() {
        let bb = BassBoostUnit()
        bb.setGainDB(20) // above max
        #expect(bb.gainDB <= 12)
        bb.setGainDB(-5) // below min
        #expect(bb.gainDB >= 0)
    }

    @Test("Shelf frequency is 80 Hz")
    func shelfFrequency() {
        let bb = BassBoostUnit()
        #expect(bb.node.bands.first?.frequency == BassBoostUnit.shelfFrequency)
    }
}

// MARK: - GainStageTests

@Suite("GainStage")
struct GainStageTests {
    @Test("Default outputVolume is 1.0 (0 dB)")
    func defaultUnity() {
        let gs = GainStage()
        #expect(abs(gs.node.outputVolume - 1.0) < 0.0001)
    }

    @Test("setGainDB(0) leaves volume at 1.0")
    func zeroDB() {
        let gs = GainStage()
        gs.setGainDB(0)
        #expect(abs(gs.node.outputVolume - 1.0) < 0.0001)
    }

    @Test("setGainDB(20) sets linear volume ≈ 10.0")
    func plus20dB() {
        let gs = GainStage()
        gs.setGainDB(20)
        #expect(abs(gs.node.outputVolume - 10.0) < 0.01)
    }

    @Test("setGainDB(-20) sets linear volume ≈ 0.1")
    func minus20dB() {
        let gs = GainStage()
        gs.setGainDB(-20)
        #expect(abs(gs.node.outputVolume - 0.1) < 0.001)
    }

    @Test("reset() restores unity gain")
    func resetRestoresUnity() {
        let gs = GainStage()
        gs.setGainDB(6)
        gs.reset()
        #expect(abs(gs.node.outputVolume - 1.0) < 0.0001)
    }

    @Test("gainDB round-trips through setGainDB")
    func roundTrip() {
        let gs = GainStage()
        gs.setGainDB(-6)
        #expect(abs(gs.gainDB - -6) < 0.1)
    }
}
