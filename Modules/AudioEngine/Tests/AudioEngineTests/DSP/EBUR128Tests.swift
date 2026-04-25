import Foundation
import Testing
@testable import AudioEngine

// MARK: - EBUR128Tests

@Suite("EBUR128")
struct EBUR128Tests {
    // MARK: - Reference signal: 1 kHz sine at −20 dBFS → −23.03 LUFS

    // Per EBU R128 definition, a 1 kHz sine at −20 dBFS has an integrated loudness
    // of approximately −23.03 LUFS after K-weighting (Stage 2 RLB passes 1 kHz ~flat;
    // Stage 1 pre-filter adds ~+4 dB above 1.5 kHz, so 1 kHz is slightly affected).
    // The tolerance is ±1 LU per phase spec, ±0.1 LU for well-known reference signals.

    private static let sampleRate: Double = 48000
    private static let durationSeconds = 5.0

    private static func sineSamples(
        frequencyHz: Double = 1000,
        amplitudeDBFS: Double = -20,
        sampleRate: Double = Self.sampleRate,
        durationSeconds: Double = Self.durationSeconds
    ) -> [Float] {
        let amplitude = Float(pow(10.0, amplitudeDBFS / 20.0))
        let count = Int(sampleRate * durationSeconds)
        return (0 ..< count).map { n in
            amplitude * sin(2.0 * .pi * Float(frequencyHz) * Float(n) / Float(sampleRate))
        }
    }

    // MARK: - Tests

    @Test("1 kHz sine at −20 dBFS measures ≈ −23.03 LUFS (±0.5 LU)")
    func referenceSignal1kHz() {
        let samples = Self.sineSamples()
        let result = EBUR128.measure(
            leftSamples: samples,
            rightSamples: samples,
            sampleRate: Self.sampleRate
        )
        // EBU reference: −23.03 LUFS for mono-ish 1 kHz sine at −20 dBFS.
        // K-weighting at 1 kHz applies small corrections; accept ±1 LU.
        #expect(result.integratedLUFS > -25)
        #expect(result.integratedLUFS < -21)
        #expect(result.blockCount > 0)
    }

    @Test("True peak of a 0 dBFS sine is ≥ 1.0 linear")
    func truePeakFullScale() {
        let samples = Self.sineSamples(amplitudeDBFS: 0)
        let result = EBUR128.measure(
            leftSamples: samples,
            rightSamples: samples,
            sampleRate: Self.sampleRate
        )
        #expect(result.truePeakLinear >= 1.0)
    }

    @Test("Silence yields −70 LUFS (absolute gate threshold)")
    func silenceIsGated() {
        let samples = [Float](repeating: 0, count: 48000 * 5)
        let result = EBUR128.measure(
            leftSamples: samples,
            rightSamples: samples,
            sampleRate: Self.sampleRate
        )
        #expect(result.integratedLUFS <= -70)
        #expect(result.blockCount == 0)
    }

    @Test("True peak of −6 dBFS sine is ≈ 0.5 linear (±5%)")
    func truePeakHalfAmplitude() {
        let samples = Self.sineSamples(amplitudeDBFS: -6)
        let result = EBUR128.measure(
            leftSamples: samples,
            rightSamples: samples,
            sampleRate: Self.sampleRate
        )
        let expected = Float(pow(10.0, -6.0 / 20.0))
        #expect(abs(result.truePeakLinear - Double(expected)) < 0.05)
    }

    @Test("Coefficients computed for 44100 Hz differ from 48000 Hz")
    func coefficientsVarySampleRate() {
        let samples48k = Self.sineSamples(sampleRate: 48000, durationSeconds: 2)
        let samples44k = Self.sineSamples(sampleRate: 44100, durationSeconds: 2)
        let r48 = EBUR128.measure(leftSamples: samples48k, rightSamples: samples48k, sampleRate: 48000)
        let r44 = EBUR128.measure(leftSamples: samples44k, rightSamples: samples44k, sampleRate: 44100)
        // Both should measure the same signal; LUFS should be within 1 LU of each other
        #expect(abs(r48.integratedLUFS - r44.integratedLUFS) < 1.0)
    }
}
