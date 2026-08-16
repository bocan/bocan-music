import Accelerate
import Foundation

// MARK: - SpectralShelfReading

/// The raw shelf measurement extracted from an averaged spectrum: where the
/// broadband content stops, and how hard it falls immediately above that point.
/// Pure measurement; the suspected/confidence policy lives in
/// ``ProvenanceAnalyzer``.
struct SpectralShelfReading: Equatable {
    /// Highest frequency (Hz) whose smoothed energy is still within
    /// ``SpectralShelf/edgeThresholdDB`` of the midband reference.
    let edgeHz: Double
    /// Level drop (dB) from the edge to the mean level 0.5–2 kHz above it.
    /// A lossy encoder's shelf is a cliff; analogue rolloff is a slope.
    let cliffDropDB: Double
}

// MARK: - SpectralShelf

/// Batch spectral analysis for transcode detection (ADR-075 slice 1).
///
/// Produces one averaged, smoothed dB power spectrum from pre-decoded mono
/// segments (8192-point Hann-windowed FFT frames, averaged per segment, then
/// averaged across segments), and measures the spectral shelf on it. Absolute
/// scale is never normalised out of the FFT because every judgement here is
/// relative to the midband reference.
enum SpectralShelf {
    // MARK: - FFT constants

    /// FFT length per frame. 8192 points gives ~5.4 Hz bins at 44.1 kHz,
    /// fine enough to place a shelf edge within the encoder-ceiling tolerance.
    static let fftSize = 8192
    /// Unique spectrum bins per frame (`fftSize / 2`).
    static let binCount = 4096
    private static let log2n = vDSP_Length(13) // 2^13 = 8192

    // MARK: - Measurement constants

    /// Midband reference range: averaged level over this band anchors "where
    /// the music is" so the edge threshold tracks the recording's own level.
    static let midbandLowHz = 1000.0
    /// Upper midband bound, clamped to 0.35 × sample rate for low-rate files.
    static let midbandHighHz = 8000.0
    /// The shelf edge is the highest frequency still within this many dB of
    /// the midband reference. Generous on purpose: natural high-frequency
    /// rolloff in real music must stay inside it.
    static let edgeThresholdDB: Float = 30
    /// Half-width (Hz) of the moving-average smoothing applied to the dB
    /// spectrum, so a single tonal bin cannot fake or hide a shelf edge.
    static let smoothingHalfWidthHz = 75.0
    /// Floor added before log conversion so digital silence stays finite.
    private static let powerFloor: Float = 1e-20

    // MARK: - Spectrum

    /// Averaged, smoothed power spectrum in dB over all usable segments.
    ///
    /// - Returns: `binCount` dB values, or `nil` when no segment holds even
    ///   one full FFT frame (nothing to judge).
    static func averagedSpectrumDB(segments: [[Float]], sampleRate: Double) -> [Float]? {
        guard sampleRate > 0, let setup = vDSP_create_fftsetup(self.log2n, FFTRadix(FFT_RADIX2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: self.fftSize,
            isHalfWindow: false
        )
        let segmentSpectra = segments.compactMap { self.segmentPower($0, window: window, setup: setup) }
        guard !segmentSpectra.isEmpty else { return nil }

        var mean = [Float](repeating: 0, count: self.binCount)
        for spectrum in segmentSpectra {
            vDSP_vadd(mean, 1, spectrum, 1, &mean, 1, vDSP_Length(self.binCount))
        }
        var segmentScale = 1.0 / Float(segmentSpectra.count)
        vDSP_vsmul(mean, 1, &segmentScale, &mean, 1, vDSP_Length(self.binCount))

        let decibels = mean.map { 10 * log10(max($0, self.powerFloor)) }
        let freqPerBin = sampleRate / Double(self.fftSize)
        return self.smoothed(decibels, radius: max(1, Int(self.smoothingHalfWidthHz / freqPerBin)))
    }

    /// Mean power spectrum of one segment over consecutive non-overlapping
    /// Hann-windowed frames. Returns `nil` when the segment is shorter than
    /// one frame.
    private static func segmentPower(_ segment: [Float], window: [Float], setup: FFTSetup) -> [Float]? {
        guard segment.count >= self.fftSize else { return nil }
        var accumulated = [Float](repeating: 0, count: self.binCount)
        var windowed = [Float](repeating: 0, count: self.fftSize)
        var realp = [Float](repeating: 0, count: self.binCount)
        var imagp = [Float](repeating: 0, count: self.binCount)
        var magnitudes = [Float](repeating: 0, count: self.binCount)
        var frames = 0
        var offset = 0
        while offset + self.fftSize <= segment.count {
            segment.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                vDSP_vmul(base + offset, 1, window, 1, &windowed, 1, vDSP_Length(self.fftSize))
            }
            realp.withUnsafeMutableBufferPointer { realBuffer in
                imagp.withUnsafeMutableBufferPointer { imagBuffer in
                    guard let realBase = realBuffer.baseAddress, let imagBase = imagBuffer.baseAddress else {
                        return
                    }
                    var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                    windowed.withUnsafeBytes { rawBytes in
                        rawBytes.withMemoryRebound(to: DSPComplex.self) { complexSpan in
                            guard let complexBase = complexSpan.baseAddress else { return }
                            vDSP_ctoz(complexBase, 2, &split, 1, vDSP_Length(self.binCount))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, self.log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(self.binCount))
                }
            }
            vDSP_vadd(accumulated, 1, magnitudes, 1, &accumulated, 1, vDSP_Length(self.binCount))
            frames += 1
            offset += self.fftSize
        }
        guard frames > 0 else { return nil }
        var frameScale = 1.0 / Float(frames)
        vDSP_vsmul(accumulated, 1, &frameScale, &accumulated, 1, vDSP_Length(self.binCount))
        return accumulated
    }

    // MARK: - Shelf measurement

    /// Locates the content edge and measures the cliff above it.
    ///
    /// - Returns: `nil` when the sample rate is too low to place a midband
    ///   reference, or when nothing above the midband floor carries energy
    ///   (the caller treats both as "cannot judge", never as suspected).
    static func reading(spectrumDB: [Float], sampleRate: Double) -> SpectralShelfReading? {
        let freqPerBin = sampleRate / Double(self.fftSize)
        let midbandHigh = min(self.midbandHighHz, sampleRate * 0.35)
        guard freqPerBin > 0, midbandHigh > self.midbandLowHz else { return nil }
        let refLow = Int(self.midbandLowHz / freqPerBin)
        let refHigh = Int(midbandHigh / freqPerBin)
        guard refLow >= 0, refHigh > refLow, refHigh < spectrumDB.count else { return nil }
        let reference = spectrumDB[refLow ... refHigh].reduce(0, +) / Float(refHigh - refLow + 1)

        // Walk down from Nyquist: the edge is the highest bin still within
        // the threshold of the midband reference. Searching down into the
        // midband itself keeps shelves below `midbandHigh` detectable.
        var edgeBin: Int?
        var bin = spectrumDB.count - 1
        while bin > refLow {
            if spectrumDB[bin] >= reference - self.edgeThresholdDB {
                edgeBin = bin
                break
            }
            bin -= 1
        }
        guard let edgeBin else { return nil }
        let edgeHz = Double(edgeBin) * freqPerBin

        // Cliff: edge level minus the mean level 0.5–2 kHz above the edge.
        let aboveLow = min(spectrumDB.count - 1, edgeBin + Int(500 / freqPerBin))
        let aboveHigh = min(spectrumDB.count - 1, edgeBin + Int(2000 / freqPerBin))
        guard aboveHigh > aboveLow else {
            return SpectralShelfReading(edgeHz: edgeHz, cliffDropDB: 0)
        }
        let aboveLevel = spectrumDB[aboveLow ... aboveHigh].reduce(0, +) / Float(aboveHigh - aboveLow + 1)
        return SpectralShelfReading(edgeHz: edgeHz, cliffDropDB: Double(spectrumDB[edgeBin] - aboveLevel))
    }

    // MARK: - Helpers

    /// Moving-average smoothing over `values` with the given half-width in
    /// bins, via a prefix sum so the cost stays linear.
    private static func smoothed(_ values: [Float], radius: Int) -> [Float] {
        guard radius > 0, values.count > 1 else { return values }
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for (index, value) in values.enumerated() {
            prefix[index + 1] = prefix[index] + Double(value)
        }
        return values.indices.map { index in
            let low = max(0, index - radius)
            let high = min(values.count - 1, index + radius)
            return Float((prefix[high + 1] - prefix[low]) / Double(high - low + 1))
        }
    }
}
