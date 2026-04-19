import Foundation
import Testing
@testable import Metadata

@Suite("ReplayGain")
struct ReplayGainTests {
    @Test("NaN raw values produce nil optionals")
    func nanToNil() {
        let rg = ReplayGain(
            trackGainRaw: Double.nan,
            trackPeakRaw: Double.nan,
            albumGainRaw: Double.nan,
            albumPeakRaw: Double.nan,
            r128TrackGainRaw: Double.nan,
            r128AlbumGainRaw: Double.nan
        )
        #expect(rg.isEmpty)
        #expect(rg.trackGain == nil)
        #expect(rg.trackPeak == nil)
    }

    @Test("finite raw values are preserved")
    func finiteValues() {
        let rg = ReplayGain(
            trackGainRaw: -3.21,
            trackPeakRaw: 0.98,
            albumGainRaw: -2.10,
            albumPeakRaw: 0.95,
            r128TrackGainRaw: -5.0,
            r128AlbumGainRaw: Double.nan
        )
        #expect(rg.trackGain == -3.21)
        #expect(rg.trackPeak == 0.98)
        #expect(rg.albumGain == -2.10)
        #expect(rg.albumPeak == 0.95)
        #expect(rg.r128TrackGain == -5.0)
        #expect(rg.r128AlbumGain == nil)
        #expect(!rg.isEmpty)
    }

    @Test("public init preserves optionals")
    func publicInit() {
        let rg = ReplayGain(trackGain: -1.0)
        #expect(rg.trackGain == -1.0)
        #expect(rg.trackPeak == nil)
    }
}
