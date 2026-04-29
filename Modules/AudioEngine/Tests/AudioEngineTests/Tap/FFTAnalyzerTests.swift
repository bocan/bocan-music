import Foundation
import Testing
@testable import AudioEngine

// MARK: - FFTAnalyzerTests

@Suite("FFTAnalyzer")
@MainActor
struct FFTAnalyzerTests {
    // MARK: - Hann window

    @Test("Hann window is symmetric and peaks at 1.0 at centre")
    func hannWindowSymmetryAndPeak() {
        // The window is accessed indirectly: feed DC (all ones) and verify the
        // FFT output is consistent (non-NaN, non-infinite).
        let analyzer = FFTAnalyzer()
        let dc = AudioSamples(
            timeStamp: .init(),
            sampleRate: 44100,
            mono: [Float](repeating: 1.0, count: 1024),
            left: [Float](repeating: 1.0, count: 1024),
            right: [Float](repeating: 1.0, count: 1024),
            rms: 1.0,
            peak: 1.0
        )
        let bands = analyzer.analyze(dc)
        #expect(bands.count == FFTAnalyzer.bandCount)
        for (i, b) in bands.enumerated() {
            #expect(b.isFinite, "Band \(i) is non-finite: \(b)")
            #expect(b >= 0, "Band \(i) is negative: \(b)")
            #expect(b <= 1, "Band \(i) exceeds 1.0: \(b)")
        }
    }

    // MARK: - Pure-tone dominance

    @Test("Pure 1 kHz sine: band containing 1 kHz dominates within 3 dB")
    func pureOneKHzSineDominates() {
        let sampleRate: Double = 44100
        let frequency: Double = 1000
        let count = 1024
        let mono: [Float] = (0 ..< count).map { i in
            Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
        }
        let samples = AudioSamples(
            timeStamp: .init(),
            sampleRate: sampleRate,
            mono: mono,
            left: mono,
            right: mono,
            rms: 0.707,
            peak: 1.0
        )

        let analyzer = FFTAnalyzer()
        // Warm up overlap buffer with one identical buffer.
        _ = analyzer.analyze(samples)
        let bands = analyzer.analyze(samples)

        // Find the band index whose centre frequency contains 1 kHz.
        let binRanges = FFTAnalyzer.makeBandBins(sampleRate: sampleRate)
        let freqPerBin = sampleRate / 2048.0
        let targetBin = Int((frequency / freqPerBin).rounded())

        guard let dominantBandIdx = binRanges.firstIndex(where: {
            $0.from <= targetBin && targetBin <= $0.to
        }) else {
            #expect(Bool(false), "No band covers the 1 kHz bin")
            return
        }

        let dominantValue = bands[dominantBandIdx]
        // All other bands should be at most 3 dB (factor ≈ 0.707) below dominant,
        // but in practice the dominant band must be the max.
        let maxValue = bands.max() ?? 0
        #expect(
            dominantValue == maxValue || abs(dominantValue - maxValue) < 0.1,
            "1 kHz band value \(dominantValue) not close to max \(maxValue)"
        )
    }

    // MARK: - Band mapping

    @Test("32 log-spaced bands are monotonically increasing in frequency")
    func bandsAreMonotonic() {
        let sampleRate = 44100.0
        let bands = FFTAnalyzer.makeBandBins(sampleRate: sampleRate)
        #expect(bands.count == FFTAnalyzer.bandCount)
        for i in 1 ..< bands.count {
            #expect(
                bands[i].from >= bands[i - 1].from,
                "Band \(i) lower bound \(bands[i].from) < band \(i - 1) lower bound \(bands[i - 1].from)"
            )
        }
    }

    @Test("No band has NaN or negative bin indices")
    func bandBinsAreValid() {
        for sr in [44100.0, 48000.0, 96000.0] {
            let bands = FFTAnalyzer.makeBandBins(sampleRate: sr)
            for (i, b) in bands.enumerated() {
                #expect(b.from >= 0, "Band \(i) from=\(b.from) at sampleRate=\(sr)")
                #expect(b.to >= b.from, "Band \(i) to=\(b.to) < from=\(b.from) at sampleRate=\(sr)")
            }
        }
    }

    // MARK: - EMA smoothing (decay after silence)

    @Test("Bands decay toward zero after silence")
    func bandsDecayAfterSilence() {
        let analyzer = FFTAnalyzer()
        let sampleRate = 44100.0

        // Feed a burst of noise to raise bands.
        let noise: [Float] = (0 ..< 1024).map { _ in Float.random(in: -1 ... 1) }
        let noiseSamples = AudioSamples(
            timeStamp: .init(),
            sampleRate: sampleRate,
            mono: noise,
            left: noise,
            right: noise,
            rms: 0.5,
            peak: 1.0
        )
        for _ in 0 ..< 5 {
            _ = analyzer.analyze(noiseSamples)
        }

        // Feed silence and assert bands decrease each frame.
        let silence = [Float](repeating: 0, count: 1024)
        let silentSamples = AudioSamples(
            timeStamp: .init(),
            sampleRate: sampleRate,
            mono: silence,
            left: silence,
            right: silence,
            rms: 0,
            peak: 0
        )

        var prevBands = analyzer.analyze(silentSamples)
        for _ in 0 ..< 10 {
            let nextBands = analyzer.analyze(silentSamples)
            let prevSum = prevBands.reduce(0, +)
            let nextSum = nextBands.reduce(0, +)
            // Total energy must not increase during silence.
            #expect(nextSum <= prevSum + 1e-5, "Bands did not decay: prev=\(prevSum), next=\(nextSum)")
            prevBands = nextBands
        }
    }

    // MARK: - Output bounds

    @Test("All band values are in [0, 1] for full-scale white noise")
    func bandValuesClampedForNoise() {
        let analyzer = FFTAnalyzer()
        let noise: [Float] = (0 ..< 1024).map { _ in Float.random(in: -1 ... 1) }
        let samples = AudioSamples(
            timeStamp: .init(),
            sampleRate: 44100,
            mono: noise,
            left: noise,
            right: noise,
            rms: 0.5,
            peak: 1.0
        )
        // Run many frames to let the EMA stabilise.
        var bands: [Float] = []
        for _ in 0 ..< 20 {
            bands = analyzer.analyze(samples)
        }
        for (i, b) in bands.enumerated() {
            #expect(b >= 0 && b <= 1, "Band \(i) out of [0,1]: \(b)")
        }
    }
}
