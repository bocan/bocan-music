import Accelerate
import Foundation

// MARK: - FFTAnalyzer

/// vDSP-backed FFT analyser producing 32 perceptual frequency bands from audio samples.
///
/// **Usage** (on `@MainActor`):
/// ```swift
/// let analyzer = FFTAnalyzer()
/// let bands = analyzer.analyze(samples)   // [Float] × 32, normalised 0…1
/// ```
///
/// **Algorithm**:
/// - 2048-point real FFT with 50% overlap (accumulates two consecutive 1024-frame buffers).
/// - Hann window applied before each transform to reduce spectral leakage.
/// - Squared-magnitude bins converted to 32 log-spaced perceptual bands (20 Hz – 20 kHz).
/// - Per-band exponential moving average: fast attack (α = 0.6), slow release (α = 0.08)
///   so the visualiser responds quickly to transients but decays gracefully.
@MainActor
public final class FFTAnalyzer {
    // MARK: - Constants

    /// Number of perceptual frequency bands produced by the analyzer (log-spaced, 20 Hz–20 kHz).
    public nonisolated static let bandCount = 32
    private static let fftSize = 2048
    private static let binCount = fftSize / 2 // 1024 unique bins
    private static let log2n = vDSP_Length(11) // 2^11 = 2048

    // MARK: - Preallocated buffers (all MainActor-isolated, never crossed to RT thread)

    // nonisolated(unsafe): FFTSetup (OpaquePointer) lacks Sendable; safe because all
    // access happens on @MainActor and deinit only destroys an immutable opaque pointer.
    private nonisolated(unsafe) let fftSetup: FFTSetup
    private let hannWindow: [Float]

    private var overlapBuffer: [Float] // previous 1024 samples (50% overlap)
    private var windowedInput: [Float] // 2048-point windowed frame
    private var realpBuffer: [Float] // split-complex real part (1024)
    private var imagpBuffer: [Float] // split-complex imaginary part (1024)
    private var magnitudes: [Float] // squared magnitudes per bin (1024)
    private var smoothed: [Float] // EMA-smoothed band values (32)
    /// Per-band running peak for adaptive normalisation (slow decay).
    /// Decays ~0.15% per frame — at 43 fps a peak halves in roughly 11 s,
    /// long enough to feel stable but fast enough to adapt after a genre change.
    private var bandPeaks: [Float]

    // Band bin ranges, recomputed when sample rate changes.
    private var bandBins: [(from: Int, to: Int)]
    private var lastSampleRate: Double = 0

    // MARK: - EMA

    private let attackAlpha: Float = 0.6
    private let releaseAlpha: Float = 0.08
    private let peakDecay: Float = 0.9985

    // MARK: - Init

    public init() {
        let n = Self.fftSize
        let bins = Self.binCount

        // swiftlint:disable:next force_unwrapping
        self.fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(FFT_RADIX2))!

        // Hann window (denormalized: peak = 1.0 at centre, 0.0 at both ends).
        self.hannWindow = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: n,
            isHalfWindow: false
        )

        self.overlapBuffer = [Float](repeating: 0, count: n / 2)
        self.windowedInput = [Float](repeating: 0, count: n)
        self.realpBuffer = [Float](repeating: 0, count: bins)
        self.imagpBuffer = [Float](repeating: 0, count: bins)
        self.magnitudes = [Float](repeating: 0, count: bins)
        self.smoothed = [Float](repeating: 0, count: Self.bandCount)
        self.bandPeaks = [Float](repeating: 0, count: Self.bandCount)
        self.bandBins = []
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - Public API

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Analyse one buffer of audio, updating the overlap buffer and returning
    /// 32 normalised band values (0…1).
    ///
    /// - Parameter samples: Latest buffer from `AudioTap`.
    /// - Returns: 32 perceptual band magnitudes, normalised so a full-scale sine
    ///   at the centre frequency of a band ≈ 1.0.
    public func analyze(_ samples: AudioSamples) -> [Float] {
        if samples.sampleRate != self.lastSampleRate {
            self.lastSampleRate = samples.sampleRate
            self.bandBins = Self.makeBandBins(sampleRate: samples.sampleRate)
        }

        let mono = samples.mono
        let hop = mono.count // typically 1024

        // Assemble 2048-sample frame: previous hop + new hop.
        let frameSize = Self.fftSize
        self.windowedInput.withUnsafeMutableBufferPointer { frame in
            guard let base = frame.baseAddress else { return }
            // First half: tail of previous buffer (50% overlap).
            self.overlapBuffer.withUnsafeBufferPointer { overlap in
                guard let ob = overlap.baseAddress else { return }
                base.initialize(from: ob, count: min(hop, frameSize / 2))
            }
            // Second half: new samples.
            mono.withUnsafeBufferPointer { src in
                guard let sb = src.baseAddress else { return }
                let offset = min(hop, frameSize / 2)
                (base + offset).initialize(from: sb, count: min(hop, frameSize - offset))
            }
        }

        // Save new samples as the next overlap.
        let copyCount = min(hop, frameSize / 2)
        mono.withUnsafeBufferPointer { src in
            guard let sb = src.baseAddress else { return }
            self.overlapBuffer.withUnsafeMutableBufferPointer { dst in
                guard let db = dst.baseAddress else { return }
                db.initialize(from: sb, count: copyCount)
            }
        }

        // Apply Hann window in-place.
        vDSP_vmul(self.windowedInput, 1, self.hannWindow, 1, &self.windowedInput, 1, vDSP_Length(frameSize))

        // Pack real signal into split-complex (even → realp, odd → imagp).
        self.realpBuffer.withUnsafeMutableBufferPointer { rp in
            self.imagpBuffer.withUnsafeMutableBufferPointer { ip in
                guard let realBase = rp.baseAddress, let imagBase = ip.baseAddress else { return }
                var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)
                self.windowedInput.withUnsafeBytes { rawBytes in
                    rawBytes.withMemoryRebound(to: DSPComplex.self) { complexSpan in
                        guard let src = complexSpan.baseAddress else { return }
                        vDSP_ctoz(src, 2, &splitComplex, 1, vDSP_Length(Self.binCount))
                    }
                }

                // Forward FFT (in-place).
                vDSP_fft_zrip(self.fftSetup, &splitComplex, 1, Self.log2n, FFTDirection(FFT_FORWARD))

                // Squared magnitudes for all bins.
                vDSP_zvmags(&splitComplex, 1, &self.magnitudes, 1, vDSP_Length(Self.binCount))
            }
        }

        // Normalise by 1/(N²) to remove the vDSP FFT scaling factor.
        let n2 = Float(Self.fftSize * Self.fftSize)
        var invN2 = 1.0 / n2
        vDSP_vsmul(self.magnitudes, 1, &invN2, &self.magnitudes, 1, vDSP_Length(Self.binCount))

        // Accumulate bins into log-spaced perceptual bands.
        var bands = [Float](repeating: 0, count: Self.bandCount)
        self.magnitudes.withUnsafeBufferPointer { magBuf in
            guard let magBase = magBuf.baseAddress else { return }
            for (i, range) in self.bandBins.enumerated() where i < Self.bandCount {
                let span = range.to - range.from + 1
                guard span > 0 else { continue }
                var sum: Float = 0
                vDSP_sve(magBase.advanced(by: range.from), 1, &sum, vDSP_Length(span))
                // Average per bin, then sqrt for amplitude (not power) display.
                bands[i] = sqrt(sum / Float(span))
            }
        }

        // EMA: fast attack when magnitude rises, slow release when it falls.
        for i in 0 ..< Self.bandCount {
            let alpha = bands[i] > self.smoothed[i] ? self.attackAlpha : self.releaseAlpha
            self.smoothed[i] = alpha * bands[i] + (1 - alpha) * self.smoothed[i]
        }

        // Per-band adaptive normalisation.
        //
        // Each band tracks its own running peak (slow EMA decay).  Dividing by
        // the per-band peak instead of the global maximum means every frequency
        // band fills the full 0…1 range whenever it has *any* content — bass,
        // mids, and high-frequency bands all scale independently.  Without this,
        // the bass dominates the global max and high-frequency bands (which have
        // far less raw energy) are crushed to near zero and never appear.
        //
        // Threshold: if a band's peak has never risen above 1 % of full scale
        // (i.e. the frequency band genuinely has no content) the output is 0
        // rather than amplifying noise.
        var result = [Float](repeating: 0, count: Self.bandCount)
        for i in 0 ..< Self.bandCount {
            let val = self.smoothed[i]
            self.bandPeaks[i] = max(val, self.bandPeaks[i] * self.peakDecay)
            let peak = self.bandPeaks[i]
            result[i] = peak > 1e-4 ? val / peak : 0
        }
        // Hard clamp to [0, 1].
        var zero: Float = 0
        var one: Float = 1
        vDSP_vclip(result, 1, &zero, &one, &result, 1, vDSP_Length(Self.bandCount))

        return result
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

    // MARK: - Internal: band mapping

    /// Returns 32 `(from: binIndex, to: binIndex)` pairs covering 20 Hz – 20 kHz
    /// on a log scale, given the current sample rate.
    static func makeBandBins(sampleRate: Double) -> [(from: Int, to: Int)] {
        let binCount = Self.binCount
        let freqPerBin = sampleRate / Double(Self.fftSize)
        let minFreq: Double = 20
        let maxFreq: Double = 20000
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let count = Self.bandCount

        return (0 ..< count).map { i in
            let lowFreq = pow(10, logMin + Double(i) * (logMax - logMin) / Double(count))
            let highFreq = pow(10, logMin + Double(i + 1) * (logMax - logMin) / Double(count))
            let fromBin = max(1, Int((lowFreq / freqPerBin).rounded(.down)))
            let toBin = min(binCount - 1, Int((highFreq / freqPerBin).rounded(.up)))
            return (from: fromBin, to: max(fromBin, toBin))
        }
    }
}
