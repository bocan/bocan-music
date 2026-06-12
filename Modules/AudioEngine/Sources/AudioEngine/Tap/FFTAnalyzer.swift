import Accelerate
import Foundation

// MARK: - SpectrumFrame

/// One frame of enriched spectral analysis produced by ``FFTAnalyzer/analyze(_:)``.
///
/// Every field is derived from the real FFT magnitudes of the audio tap; there
/// is no synthetic animation data. All values are computed on `@MainActor`,
/// never on the realtime thread.
public struct SpectrumFrame: Sendable {
    /// 32 perceptual bands, 0…1 (unchanged semantics).
    public let bands: [Float]
    /// Spectral centroid on a log-frequency scale, 0…1
    /// (0 = 20 Hz, 1 = 20 kHz). EMA-smoothed; relaxes toward 0.5 in silence.
    public let centroid: Float
    /// Positive spectral flux, normalised 0…1 by a running flux peak.
    public let flux: Float
    /// True when this frame contains a detected onset (transient).
    public let onset: Bool
    /// Mean of bands 0..<10, 10..<22, 22..<32 respectively, each 0…1.
    public let bassEnergy: Float
    public let midEnergy: Float
    public let trebleEnergy: Float

    public init(
        bands: [Float],
        centroid: Float,
        flux: Float,
        onset: Bool,
        bassEnergy: Float,
        midEnergy: Float,
        trebleEnergy: Float
    ) {
        self.bands = bands
        self.centroid = centroid
        self.flux = flux
        self.onset = onset
        self.bassEnergy = bassEnergy
        self.midEnergy = midEnergy
        self.trebleEnergy = trebleEnergy
    }
}

// MARK: - FFTAnalyzer

/// vDSP-backed FFT analyser producing 32 perceptual frequency bands from audio samples.
///
/// **Usage** (on `@MainActor`):
/// ```swift
/// let analyzer = FFTAnalyzer()
/// let frame = analyzer.analyze(samples)   // SpectrumFrame: bands ×32 + v2 features
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

    /// Band bin ranges, recomputed when sample rate changes.
    private var bandBins: [(from: Int, to: Int)]
    /// Per-bin centre frequency in Hz, recomputed when sample rate changes.
    /// Used as the weighting vector for the spectral-centroid dot product.
    private var binFrequencies: [Float]
    private var lastSampleRate: Double = 0

    // MARK: - Analysis v2 state (centroid / flux / onset)

    /// Pre-EMA band values from the previous frame. Flux is computed against the
    /// raw (unsmoothed) bands because the smoothed values smear transients.
    private var prevRawBands: [Float]
    /// Running peak of the raw spectral flux, for adaptive 0…1 normalisation.
    private var fluxPeak: Float = 0
    /// Ring buffer of recent normalised-flux values for the adaptive onset threshold.
    private var fluxHistory: [Float]
    private var fluxHistoryIndex = 0
    private var fluxHistorySum: Float = 0
    /// Frames remaining before another onset may fire (transient debounce).
    private var refractoryCounter = 0
    /// EMA-smoothed spectral centroid, 0…1. Starts (and relaxes in silence) at 0.5.
    private var centroidEMA: Float = 0.5

    // MARK: - EMA

    private let attackAlpha: Float = 0.6
    private let releaseAlpha: Float = 0.08
    private let peakDecay: Float = 0.995 // ~3 s half-life at 43 fps; was 0.9985 (11 s)

    // MARK: - Analysis v2 constants

    private let centroidAlpha: Float = 0.2 // EMA smoothing for the centroid
    private static let fluxWindow = 43 // ~1 s of frames for the onset moving average
    private let onsetThresholdMultiplier: Float = 1.8 // flux must exceed 1.8× the local mean
    private let onsetFloor: Float = 0.05 // absolute floor so silence cannot trigger onsets
    private let onsetRefractoryFrames = 4 // ~100 ms debounce: one kick → one onset
    private let fluxPeakFloor: Float = 1e-4 // mirrors the bandPeaks content threshold
    private static let minCentroidFreq: Double = 20
    private static let maxCentroidFreq: Double = 20000

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
        self.binFrequencies = [Float](repeating: 0, count: bins)
        self.prevRawBands = [Float](repeating: 0, count: Self.bandCount)
        self.fluxHistory = [Float](repeating: 0, count: Self.fluxWindow)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - Public API

    /// Reset all transient analysis state.
    ///
    /// Call this before starting to analyze a new audio stream (e.g., after a
    /// track change or tap restart) so that adaptive normalisation peaks from
    /// the previous track do not pollute the new one.
    public func reset() {
        self.smoothed = [Float](repeating: 0, count: Self.bandCount)
        self.bandPeaks = [Float](repeating: 0, count: Self.bandCount)
        self.overlapBuffer = [Float](repeating: 0, count: Self.fftSize / 2)
        // Analysis v2 transient state.
        self.prevRawBands = [Float](repeating: 0, count: Self.bandCount)
        self.fluxPeak = 0
        self.fluxHistory = [Float](repeating: 0, count: Self.fluxWindow)
        self.fluxHistoryIndex = 0
        self.fluxHistorySum = 0
        self.refractoryCounter = 0
        self.centroidEMA = 0.5
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Analyse one buffer of audio, updating the overlap buffer and returning a
    /// ``SpectrumFrame``: 32 normalised band values (0…1) plus the v2 features
    /// (centroid, flux, onset, and bass/mid/treble energy aggregates).
    ///
    /// - Parameter samples: Latest buffer from `AudioTap`.
    /// - Returns: A ``SpectrumFrame`` whose `bands` are normalised so a full-scale
    ///   sine at the centre frequency of a band ≈ 1.0.
    public func analyze(_ samples: AudioSamples) -> SpectrumFrame {
        if samples.sampleRate != self.lastSampleRate {
            self.lastSampleRate = samples.sampleRate
            self.bandBins = Self.makeBandBins(sampleRate: samples.sampleRate)
            // Per-bin centre frequencies: bin i sits at i · (sampleRate / fftSize).
            var start: Float = 0
            var step = Float(samples.sampleRate / Double(Self.fftSize))
            vDSP_vramp(&start, &step, &self.binFrequencies, 1, vDSP_Length(Self.binCount))
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

        // Analysis v2 features, all derived from data already in hand this frame.
        self.updateCentroid()
        let flux = self.computeFlux(rawBands: bands)
        let onset = self.detectOnset(flux: flux)
        self.prevRawBands = bands

        // Energy aggregates over the final normalised bands (32 = 10 + 12 + 10).
        let bassEnergy = result[0 ..< 10].reduce(0, +) / 10
        let midEnergy = result[10 ..< 22].reduce(0, +) / 12
        let trebleEnergy = result[22 ..< 32].reduce(0, +) / 10

        return SpectrumFrame(
            bands: result,
            centroid: self.centroidEMA,
            flux: flux,
            onset: onset,
            bassEnergy: bassEnergy,
            midEnergy: midEnergy,
            trebleEnergy: trebleEnergy
        )
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

    // MARK: - Internal: analysis v2 features

    /// Updates ``centroidEMA`` from the current squared-magnitude spectrum.
    ///
    /// Centroid frequency = `Σ(freqᵢ · magᵢ) / Σ(magᵢ)`, mapped onto a 20 Hz–20 kHz
    /// log scale and EMA-smoothed. When the spectrum is effectively silent the
    /// centroid relaxes toward the neutral midpoint (0.5) instead of collapsing.
    private func updateCentroid() {
        var totalMagnitude: Float = 0
        vDSP_sve(self.magnitudes, 1, &totalMagnitude, vDSP_Length(Self.binCount))
        if totalMagnitude < 1e-7 {
            self.centroidEMA += self.centroidAlpha * (0.5 - self.centroidEMA)
            return
        }
        var weightedSum: Float = 0
        vDSP_dotpr(self.magnitudes, 1, self.binFrequencies, 1, &weightedSum, vDSP_Length(Self.binCount))
        let centroidHz = Double(weightedSum / totalMagnitude)
        let logMin = log10(Self.minCentroidFreq)
        let logMax = log10(Self.maxCentroidFreq)
        let mapped = centroidHz <= Self.minCentroidFreq ? 0 : (log10(centroidHz) - logMin) / (logMax - logMin)
        let target = Float(min(1, max(0, mapped)))
        self.centroidEMA += self.centroidAlpha * (target - self.centroidEMA)
    }

    /// Positive spectral flux against the previous frame's *raw* bands, normalised
    /// 0…1 by a running peak (with a content floor, like ``bandPeaks``).
    private func computeFlux(rawBands: [Float]) -> Float {
        var rawFlux: Float = 0
        for i in 0 ..< Self.bandCount {
            let delta = rawBands[i] - self.prevRawBands[i]
            if delta > 0 { rawFlux += delta }
        }
        self.fluxPeak = max(rawFlux, self.fluxPeak * self.peakDecay)
        return self.fluxPeak > self.fluxPeakFloor ? rawFlux / self.fluxPeak : 0
    }

    /// Detects a transient: normalised flux exceeding an adaptive local-mean
    /// threshold and an absolute floor, debounced by a short refractory period.
    private func detectOnset(flux: Float) -> Bool {
        let movingAverage = self.fluxHistorySum / Float(Self.fluxWindow)
        let isCandidate = flux > self.onsetThresholdMultiplier * movingAverage && flux > self.onsetFloor

        var onset = false
        if self.refractoryCounter > 0 {
            self.refractoryCounter -= 1
        } else if isCandidate {
            onset = true
            self.refractoryCounter = self.onsetRefractoryFrames
        }

        // Slide the flux value into the moving-average ring buffer.
        self.fluxHistorySum -= self.fluxHistory[self.fluxHistoryIndex]
        self.fluxHistory[self.fluxHistoryIndex] = flux
        self.fluxHistorySum += flux
        self.fluxHistoryIndex = (self.fluxHistoryIndex + 1) % Self.fluxWindow

        return onset
    }

    // MARK: - Internal: band mapping

    /// Returns 32 `(from: binIndex, to: binIndex)` pairs covering 20 Hz – 20 kHz
    /// on a log scale, given the current sample rate.
    ///
    /// At 44.1 kHz, each FFT bin covers ~21.5 Hz, which means the three lowest
    /// log-spaced bands all map to the same two bins ([1, 2]) and would show
    /// identical bar heights.  To avoid this, each band's `fromBin` is clamped
    /// to at least `prevBand.toBin + 1`, so every band reads from a unique bin
    /// range.  Once the log-spaced calculation naturally produces a `fromBin`
    /// larger than the previous `toBin` (around 280 Hz at 44.1 kHz), both
    /// calculations agree and all higher-frequency bands are unaffected.
    static func makeBandBins(sampleRate: Double) -> [(from: Int, to: Int)] {
        let binCount = Self.binCount
        let freqPerBin = sampleRate / Double(Self.fftSize)
        let minFreq: Double = 20
        let maxFreq: Double = 20000
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let count = Self.bandCount

        var result: [(from: Int, to: Int)] = []
        result.reserveCapacity(count)
        var prevToBin = 0
        for i in 0 ..< count {
            let lowFreq = pow(10, logMin + Double(i) * (logMax - logMin) / Double(count))
            let highFreq = pow(10, logMin + Double(i + 1) * (logMax - logMin) / Double(count))
            let naturalFrom = max(1, Int((lowFreq / freqPerBin).rounded(.down)))
            // Ensure this band starts at a new bin so adjacent bars can't be identical.
            let fromBin = i == 0 ? naturalFrom : max(naturalFrom, prevToBin + 1)
            let toBin = min(binCount - 1, max(fromBin, Int((highFreq / freqPerBin).rounded(.up))))
            result.append((from: fromBin, to: toBin))
            prevToBin = toBin
        }
        return result
    }
}
