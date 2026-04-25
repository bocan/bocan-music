import Foundation
import Testing
@testable import AudioEngine

// MARK: - GainApplicationTests

@Suite("GainApplication")
struct GainApplicationTests {
    private let noGain = TrackGainInfo()
    private let withGains = TrackGainInfo(
        trackGainDB: -3.0,
        trackPeakLinear: 0.85,
        albumGainDB: -5.0,
        albumPeakLinear: 0.90
    )

    @Test("Mode .off always returns 0 dB")
    func offModeReturnsZero() {
        let gain = GainApplication.resolve(info: self.withGains, mode: .off)
        #expect(gain == 0)
    }

    @Test("Mode .track returns track gain + preAmp")
    func trackMode() {
        let gain = GainApplication.resolve(info: self.withGains, mode: .track, preAmpDB: 2.0)
        #expect(abs(gain - (-3.0 + 2.0)) < 0.001)
    }

    @Test("Mode .album returns album gain")
    func albumMode() {
        let gain = GainApplication.resolve(info: self.withGains, mode: .album)
        #expect(abs(gain - -5.0) < 0.001)
    }

    @Test("Mode .album falls back to track gain when album gain is absent")
    func albumFallsBack() {
        let info = TrackGainInfo(trackGainDB: -2.0, trackPeakLinear: 0.9)
        let gain = GainApplication.resolve(info: info, mode: .album)
        #expect(abs(gain - -2.0) < 0.001)
    }

    @Test("Mode .auto uses album gain when in album context")
    func autoAlbumContext() {
        let gain = GainApplication.resolve(info: self.withGains, mode: .auto, isInAlbumContext: true)
        #expect(abs(gain - -5.0) < 0.001)
    }

    @Test("Mode .auto uses track gain when NOT in album context")
    func autoTrackContext() {
        let gain = GainApplication.resolve(info: self.withGains, mode: .auto, isInAlbumContext: false)
        #expect(abs(gain - -3.0) < 0.001)
    }

    @Test("Clipping guard triggers when peak would exceed −0.5 dBFS")
    func clippingGuard() {
        // peak = -0.1 dBFS linear, gain = +6 dB → would push to +5.9 dBFS; must be clamped.
        let peakLinear = pow(10.0, -0.1 / 20.0)
        let info = TrackGainInfo(trackGainDB: 6.0, trackPeakLinear: peakLinear)
        let gain = GainApplication.resolve(info: info, mode: .track, preAmpDB: 0)
        let peakAfterGain = 20 * log10(peakLinear) + gain
        // Guard: peak must not exceed −0.5 dBFS
        #expect(peakAfterGain <= GainApplication.maxOutputPeakDBFS + 0.001)
    }

    @Test("Clipping guard does NOT trigger when peak is safely below −0.5 dBFS")
    func noClippingWhenSafe() {
        // gain = -3 dB, peak = 0.8 linear → peak after = 0.8 × 10^(-3/20) ≈ 0.566 → ~−4.9 dBFS
        let info = TrackGainInfo(trackGainDB: -3.0, trackPeakLinear: 0.8)
        let gain = GainApplication.resolve(info: info, mode: .track)
        // Should equal raw track gain (no guard needed)
        #expect(abs(gain - -3.0) < 0.001)
    }

    @Test("Absent ReplayGain values produce 0 dB in .track mode")
    func missingGainIsZero() {
        let gain = GainApplication.resolve(info: self.noGain, mode: .track)
        #expect(gain == 0)
    }

    @Test("peakDBFS round-trip")
    func peakDBFSRoundTrip() {
        let linear = 0.5
        let dbfs = GainApplication.peakDBFS(fromLinear: linear)
        let back = pow(10, dbfs / 20)
        #expect(abs(back - linear) < 0.0001)
    }

    @Test("ReplayGain 2.0: analyze result gain = −18 − LUFS")
    func replayGain2Target() {
        let integratedLUFS = -22.0
        let result = ReplayGainResult(integratedLUFS: integratedLUFS, truePeakLinear: 0.9)
        let expected = -18.0 - integratedLUFS // = +4 dB
        #expect(abs(result.trackGainDB - expected) < 0.001)
    }
}
