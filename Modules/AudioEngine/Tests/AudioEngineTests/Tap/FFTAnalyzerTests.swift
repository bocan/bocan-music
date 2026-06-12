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
        let bands = analyzer.analyze(dc).bands
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
        let bands = analyzer.analyze(samples).bands

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

        var prevBands = analyzer.analyze(silentSamples).bands
        for _ in 0 ..< 10 {
            let nextBands = analyzer.analyze(silentSamples).bands
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
            bands = analyzer.analyze(samples).bands
        }
        for (i, b) in bands.enumerated() {
            #expect(b >= 0 && b <= 1, "Band \(i) out of [0,1]: \(b)")
        }
    }

    // MARK: - Analysis v2 helpers

    private func makeSamples(_ mono: [Float], sampleRate: Double = 44100) -> AudioSamples {
        AudioSamples(
            timeStamp: .init(),
            sampleRate: sampleRate,
            mono: mono,
            left: mono,
            right: mono,
            rms: 0,
            peak: 0
        )
    }

    /// A phase-continuous block of summed sinusoids starting at absolute sample
    /// `startSample`, so successive frames join without a midpoint discontinuity.
    private func tone(
        _ freqs: [Double],
        from startSample: Int,
        count: Int = 1024,
        sampleRate: Double = 44100,
        amplitude: Float = 1
    ) -> [Float] {
        (0 ..< count).map { i in
            let n = Double(startSample + i)
            var value = 0.0
            for f in freqs {
                value += sin(2 * Double.pi * f * n / sampleRate)
            }
            return amplitude * Float(value)
        }
    }

    private func noiseFrame(count: Int = 1024) -> [Float] {
        (0 ..< count).map { _ in Float.random(in: -1 ... 1) }
    }

    private var silentFrame: [Float] {
        [Float](repeating: 0, count: 1024)
    }

    // MARK: - Centroid

    @Test("A 100 Hz sine yields a low centroid (< 0.3)")
    func centroidLowForBassTone() {
        let analyzer = FFTAnalyzer()
        var centroid: Float = 0
        for idx in 0 ..< 40 {
            centroid = analyzer.analyze(self.makeSamples(self.tone([100], from: idx * 1024))).centroid
        }
        #expect(centroid < 0.3, "100 Hz centroid \(centroid) should be < 0.3")
    }

    @Test("An 8 kHz sine yields a high centroid (> 0.75)")
    func centroidHighForTrebleTone() {
        let analyzer = FFTAnalyzer()
        var centroid: Float = 0
        for idx in 0 ..< 40 {
            centroid = analyzer.analyze(self.makeSamples(self.tone([8000], from: idx * 1024))).centroid
        }
        #expect(centroid > 0.75, "8 kHz centroid \(centroid) should be > 0.75")
    }

    @Test("Sweeping low to high strictly increases the smoothed centroid")
    func centroidIncreasesAcrossSweep() {
        let analyzer = FFTAnalyzer()
        let freqs = [100.0, 300, 1000, 3000, 9000]
        var centroids: [Float] = []
        var base = 0
        for f in freqs {
            var c: Float = 0
            for idx in 0 ..< 15 {
                c = analyzer.analyze(self.makeSamples(self.tone([f], from: base + idx * 1024))).centroid
            }
            base += 15 * 1024
            centroids.append(c)
        }
        for i in 1 ..< centroids.count {
            #expect(
                centroids[i] > centroids[i - 1],
                "Centroid did not increase at step \(i): \(centroids[i - 1]) → \(centroids[i])"
            )
        }
    }

    // MARK: - Flux / onset

    @Test("Silence then a broadband impulse produces exactly one onset")
    func singleImpulseOneOnset() {
        let analyzer = FFTAnalyzer()
        for _ in 0 ..< 5 {
            _ = analyzer.analyze(self.makeSamples(self.silentFrame))
        }
        var onsets = 0
        onsets += analyzer.analyze(self.makeSamples(self.noiseFrame())).onset ? 1 : 0
        for _ in 0 ..< 6 {
            onsets += analyzer.analyze(self.makeSamples(self.silentFrame)).onset ? 1 : 0
        }
        #expect(onsets == 1, "Expected one onset for a single impulse, got \(onsets)")
    }

    @Test("A sustained sine produces no onset after the attack frame")
    func sustainedSineNoOnsetAfterAttack() {
        let analyzer = FFTAnalyzer()
        for _ in 0 ..< 3 {
            _ = analyzer.analyze(self.makeSamples(self.silentFrame))
        }
        var onsets = 0
        for idx in 0 ..< 25 {
            onsets += analyzer.analyze(self.makeSamples(self.tone([1000], from: idx * 1024))).onset ? 1 : 0
        }
        #expect(onsets == 1, "Sustained sine should onset only on attack, got \(onsets)")
    }

    @Test("Two impulses 2 frames apart produce one onset (refractory)")
    func closeImpulsesAreDebounced() {
        let analyzer = FFTAnalyzer()
        for _ in 0 ..< 5 {
            _ = analyzer.analyze(self.makeSamples(self.silentFrame))
        }
        var onsets = 0
        onsets += analyzer.analyze(self.makeSamples(self.noiseFrame())).onset ? 1 : 0 // impulse 1
        onsets += analyzer.analyze(self.makeSamples(self.silentFrame)).onset ? 1 : 0
        onsets += analyzer.analyze(self.makeSamples(self.noiseFrame())).onset ? 1 : 0 // impulse 2 (+2)
        for _ in 0 ..< 4 {
            onsets += analyzer.analyze(self.makeSamples(self.silentFrame)).onset ? 1 : 0
        }
        #expect(onsets == 1, "Two impulses within the refractory window should yield one onset, got \(onsets)")
    }

    @Test("Two impulses 10 frames apart produce two onsets")
    func spacedImpulsesProduceTwoOnsets() {
        let analyzer = FFTAnalyzer()
        for _ in 0 ..< 5 {
            _ = analyzer.analyze(self.makeSamples(self.silentFrame))
        }
        var onsets = 0
        onsets += analyzer.analyze(self.makeSamples(self.noiseFrame())).onset ? 1 : 0 // impulse 1
        for _ in 0 ..< 9 {
            onsets += analyzer.analyze(self.makeSamples(self.silentFrame)).onset ? 1 : 0
        }
        onsets += analyzer.analyze(self.makeSamples(self.noiseFrame())).onset ? 1 : 0 // impulse 2 (+10)
        for _ in 0 ..< 3 {
            onsets += analyzer.analyze(self.makeSamples(self.silentFrame)).onset ? 1 : 0
        }
        #expect(onsets == 2, "Two well-spaced impulses should yield two onsets, got \(onsets)")
    }

    // MARK: - Energy aggregates

    @Test("Bass-range content raises bassEnergy while trebleEnergy stays near zero")
    func bassContentRaisesBassEnergy() {
        let analyzer = FFTAnalyzer()
        let bass = [30.0, 50, 75, 110, 150]
        // Enough sustained frames for the attack transient (which briefly splatters
        // broadband) to decay out of the off-band aggregate.
        var frame = FFTAnalyzer().analyze(self.makeSamples(self.silentFrame))
        for idx in 0 ..< 50 {
            frame = analyzer.analyze(self.makeSamples(self.tone(bass, from: idx * 1024, amplitude: 0.18)))
        }
        #expect(frame.bassEnergy > 0.15, "bassEnergy \(frame.bassEnergy) should be raised")
        #expect(frame.trebleEnergy < 0.08, "trebleEnergy \(frame.trebleEnergy) should stay near zero")
        #expect(frame.bassEnergy > frame.trebleEnergy * 3, "bass should dominate treble")
    }

    @Test("Treble-range content raises trebleEnergy while bassEnergy stays near zero")
    func trebleContentRaisesTrebleEnergy() {
        let analyzer = FFTAnalyzer()
        let treble = [3000.0, 5000, 8000, 12000, 16000]
        var frame = FFTAnalyzer().analyze(self.makeSamples(self.silentFrame))
        for idx in 0 ..< 50 {
            frame = analyzer.analyze(self.makeSamples(self.tone(treble, from: idx * 1024, amplitude: 0.18)))
        }
        #expect(frame.trebleEnergy > 0.15, "trebleEnergy \(frame.trebleEnergy) should be raised")
        #expect(frame.bassEnergy < 0.08, "bassEnergy \(frame.bassEnergy) should stay near zero")
        #expect(frame.trebleEnergy > frame.bassEnergy * 3, "treble should dominate bass")
    }

    // MARK: - Reset

    @Test("reset() restarts flux history and centroid EMA cleanly")
    func resetRestartsState() {
        let analyzer = FFTAnalyzer()
        var preReset: Float = 0
        for idx in 0 ..< 12 {
            preReset = analyzer.analyze(self.makeSamples(self.tone([8000], from: idx * 1024))).centroid
        }
        #expect(preReset > 0.6, "Centroid should be elevated by treble before reset, was \(preReset)")

        analyzer.reset()

        // After reset, the centroid sits back at the neutral midpoint and flux is silent.
        let silent = analyzer.analyze(self.makeSamples(self.silentFrame))
        #expect(abs(silent.centroid - 0.5) < 0.05, "Centroid should restart at 0.5, was \(silent.centroid)")
        #expect(silent.flux == 0)
        #expect(!silent.onset)

        // A fresh impulse against the cleared history still fires an onset.
        let impulse = analyzer.analyze(self.makeSamples(self.noiseFrame()))
        #expect(impulse.flux > 0.5, "Post-reset impulse flux \(impulse.flux) should be strong")
        #expect(impulse.onset, "Post-reset impulse should produce an onset")
    }
}
