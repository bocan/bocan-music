import Accelerate
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - ProvenanceAnalyzerTests

/// Phase 24-1 contract: everything is judged on synthesized PCM only. Full-band
/// noise must pass clean, a lossy-style brick-wall shelf must be suspected with
/// high confidence, and an analogue-style gradual rolloff must stay clean.
@Suite("ProvenanceAnalyzer")
struct ProvenanceAnalyzerTests {
    // MARK: - Synthesized signals

    /// One segment is 2^17 samples: exactly 16 non-overlapping FFT frames,
    /// and a power of two so the shaping FFT below needs no padding.
    private static let segmentLength = 1 << 17
    private static let segmentLog2n = vDSP_Length(17)

    /// Deterministic SplitMix64 so the noise fixtures never vary between runs.
    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            self.state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = self.state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }

    /// White noise with an exact per-frequency amplitude `gain` applied in the
    /// frequency domain (forward real FFT, scale each bin, inverse FFT), so a
    /// brick wall is a true brick wall and a slope is exactly the slope asked
    /// for. No filters to design, no transition-band surprises.
    private static func shapedNoise(
        seed: UInt64,
        sampleRate: Double,
        gain: (Double) -> Double
    ) -> [Float] {
        var generator = SplitMix64(seed: seed)
        var samples = (0 ..< self.segmentLength).map { _ in
            Float.random(in: -0.5 ... 0.5, using: &generator)
        }
        self.applySpectralGain(to: &samples, sampleRate: sampleRate, gain: gain)
        return samples
    }

    private static func applySpectralGain(
        to samples: inout [Float],
        sampleRate: Double,
        gain: (Double) -> Double
    ) {
        let count = samples.count
        let half = count / 2
        guard let setup = vDSP_create_fftsetup(self.segmentLog2n, FFTRadix(FFT_RADIX2)) else { return }
        defer { vDSP_destroy_fftsetup(setup) }
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        let freqPerBin = sampleRate / Double(count)
        realp.withUnsafeMutableBufferPointer { realBuffer in
            imagp.withUnsafeMutableBufferPointer { imagBuffer in
                guard let realBase = realBuffer.baseAddress, let imagBase = imagBuffer.baseAddress else {
                    return
                }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                samples.withUnsafeBytes { rawBytes in
                    rawBytes.withMemoryRebound(to: DSPComplex.self) { complexSpan in
                        guard let complexBase = complexSpan.baseAddress else { return }
                        vDSP_ctoz(complexBase, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, self.segmentLog2n, FFTDirection(FFT_FORWARD))
                // Bin 0 packs DC in realp and Nyquist in imagp.
                realBase[0] *= Float(gain(0))
                imagBase[0] *= Float(gain(sampleRate / 2))
                for bin in 1 ..< half {
                    let factor = Float(gain(Double(bin) * freqPerBin))
                    realBase[bin] *= factor
                    imagBase[bin] *= factor
                }
                vDSP_fft_zrip(setup, &split, 1, self.segmentLog2n, FFTDirection(FFT_INVERSE))
                samples.withUnsafeMutableBytes { rawBytes in
                    rawBytes.withMemoryRebound(to: DSPComplex.self) { complexSpan in
                        guard let complexBase = complexSpan.baseAddress else { return }
                        vDSP_ztoc(&split, 1, complexBase, 2, vDSP_Length(half))
                    }
                }
            }
        }
        // A zrip forward + inverse round trip scales by 2N; undo it.
        var scale = 1 / Float(2 * count)
        vDSP_vsmul(samples, 1, &scale, &samples, 1, vDSP_Length(count))
    }

    /// Three independently seeded segments of the same spectral shape, as the
    /// file driver would hand over from its three sample windows.
    private static func segments(sampleRate: Double, gain: (Double) -> Double) -> [[Float]] {
        [1, 2, 3].map { seed in
            self.shapedNoise(seed: UInt64(seed) &* 0x9E37_79B9, sampleRate: sampleRate, gain: gain)
        }
    }

    // MARK: - Verdict tests

    @Test("Full-band noise is not suspected")
    func fullBandNoiseIsClean() {
        let verdict = ProvenanceAnalyzer.analyze(
            segments: Self.segments(sampleRate: 44100) { _ in 1 },
            sampleRate: 44100
        )
        #expect(!verdict.suspected)
        #expect(verdict.confidence == 0)
        #expect(verdict.shelfFrequencyHz == nil)
    }

    @Test("A 16 kHz brick wall in a 44.1 kHz stream is suspected with high confidence")
    func brickWall16kIsSuspected() {
        let verdict = ProvenanceAnalyzer.analyze(
            segments: Self.segments(sampleRate: 44100) { frequency in frequency < 16000 ? 1 : 0 },
            sampleRate: 44100
        )
        #expect(verdict.suspected)
        #expect(verdict.confidence >= 0.7)
        let shelf = verdict.shelfFrequencyHz ?? 0
        #expect(abs(shelf - 16000) <= 500, "shelf edge should sit at the 128k MP3 ceiling, got \(shelf) Hz")
    }

    @Test("Gently rolled-off analogue-style noise stays clean")
    func analogueRolloffIsClean() {
        // -36 dB/octave above 6 kHz: steep for an analogue source, but a
        // slope, not a cliff. The edge lands near 11 kHz (well below the
        // lossless ceiling) so this exercises the steepness branch, not the
        // frequency gate.
        let verdict = ProvenanceAnalyzer.analyze(
            segments: Self.segments(sampleRate: 44100) { frequency in
                frequency <= 6000 ? 1 : pow(6000 / frequency, 6)
            },
            sampleRate: 44100
        )
        #expect(!verdict.suspected)
        #expect(verdict.confidence == 0)
        #expect(verdict.shelfFrequencyHz == nil)
    }

    @Test("A 21 kHz shelf at 44.1 kHz reads as an anti-alias filter, not a transcode")
    func antiAliasShelfIsClean() {
        let verdict = ProvenanceAnalyzer.analyze(
            segments: Self.segments(sampleRate: 44100) { frequency in frequency < 21000 ? 1 : 0 },
            sampleRate: 44100
        )
        #expect(!verdict.suspected)
    }

    @Test("A 20 kHz shelf in a 48 kHz stream is judged against 48 kHz, not 44.1")
    func sampleRateAwareAt48k() {
        // At 44.1 kHz a 20 kHz edge would sit above the lossless ceiling and
        // pass clean; at 48 kHz it is a classic 320k ceiling and must not.
        let verdict = ProvenanceAnalyzer.analyze(
            segments: Self.segments(sampleRate: 48000) { frequency in frequency < 20000 ? 1 : 0 },
            sampleRate: 48000
        )
        #expect(verdict.suspected)
        #expect(verdict.confidence >= 0.7)
        let shelf = verdict.shelfFrequencyHz ?? 0
        #expect(abs(shelf - 20000) <= 500, "shelf edge should sit at the 320k ceiling, got \(shelf) Hz")
    }

    @Test("Empty and too-short input yields a clean verdict instead of crashing")
    func degenerateInputIsClean() {
        let empty = ProvenanceAnalyzer.analyze(segments: [], sampleRate: 44100)
        #expect(!empty.suspected)
        #expect(empty.confidence == 0)

        let short = ProvenanceAnalyzer.analyze(
            segments: [[Float](repeating: 0, count: 1000)],
            sampleRate: 44100
        )
        #expect(!short.suspected)

        let zeroRate = ProvenanceAnalyzer.analyze(
            segments: [[Float](repeating: 0, count: Self.segmentLength)],
            sampleRate: 0
        )
        #expect(!zeroRate.suspected)
    }

    // MARK: - File driver

    @Test("The file driver reaches the same suspicion on a synthesized WAV")
    func fileDriverOnBrickWalledWAV() async throws {
        // ~6 s of 16 kHz brick-limited noise; 1 s windows keep the test quick
        // while still exercising the three-window seek path.
        let samples = Self.shapedNoise(seed: 7, sampleRate: 44100) { $0 < 16000 ? 1 : 0 }
            + Self.shapedNoise(seed: 8, sampleRate: 44100) { $0 < 16000 ? 1 : 0 }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-\(UUID().uuidString).wav")
        try Self.writeWAV(samples: samples, sampleRate: 44100, to: url)

        let verdict = try await ProvenanceAnalyzer.analyze(url: url, windowSeconds: 1)
        #expect(verdict.suspected)
        #expect(verdict.confidence >= 0.7)
        let shelf = verdict.shelfFrequencyHz ?? 0
        #expect(abs(shelf - 16000) <= 500)

        try FileManager.default.removeItem(at: url)
    }

    private static func writeWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        // Local scope so the AVAudioFile deallocates (and flushes) on return.
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0] else {
            throw URLError(.cannotCreateFile)
        }
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }
}
