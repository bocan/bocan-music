// @preconcurrency: AVAudioPCMBuffer lacks Sendable; the analyzer owns each
// buffer exclusively for the duration of a read loop.
// Remove once AVFoundation adopts Sendable annotations (FB13119463).
@preconcurrency import AVFoundation
import Foundation
import Observability

// MARK: - ProvenanceVerdict

/// The outcome of one transcode-detection pass over an audio file (phase 24).
///
/// Product stance, fixed in the phase spec: **suspected, never accused**.
/// Live recordings, old digitisations, dull source material, and legitimately
/// lossy-mastered releases all produce false positives, so a verdict is a
/// confidence-weighted suspicion, not a finding.
public struct ProvenanceVerdict: Equatable, Sendable {
    /// True when the averaged spectrum shows a lossy-encoder shelf: broadband
    /// content ending below ``ProvenanceAnalyzer/losslessCeilingFraction`` of
    /// the sample rate with a steep cliff immediately above the edge.
    public let suspected: Bool
    /// Heuristic confidence in the suspicion, 0…1. Always 0 when not
    /// suspected. Steeper cliffs and edges near known encoder ceilings score
    /// higher; gradual (analogue-style) rolloff never reaches suspicion.
    public let confidence: Double
    /// The shelf-edge frequency in Hz when suspected, `nil` otherwise.
    public let shelfFrequencyHz: Int?
    /// When the analysis ran.
    public let analysedAt: Date

    public init(suspected: Bool, confidence: Double, shelfFrequencyHz: Int?, analysedAt: Date) {
        self.suspected = suspected
        self.confidence = confidence
        self.shelfFrequencyHz = shelfFrequencyHz
        self.analysedAt = analysedAt
    }
}

// MARK: - ProvenanceAnalyzer

/// Scores an audio file for lossy-transcode provenance (phase 24-1).
///
/// A lossy encoder discards energy above a codec-and-bitrate-dependent
/// ceiling, and that hard spectral shelf survives re-encoding to a lossless
/// container. The analyzer decodes a few sample windows, averages their
/// 8192-point Hann spectra, and judges the shelf via ``SpectralShelf``.
///
/// All work runs on the calling task's thread and checks cancellation between
/// decode chunks, mirroring `ReplayGainAnalyzer`. Pure analysis: no
/// persistence, no UI, no I/O beyond the decode.
public struct ProvenanceAnalyzer: Sendable {
    // MARK: - Policy constants (tunable; conservative by design)

    /// Number of seconds decoded per sample window.
    public static let defaultWindowSeconds: Double = 10
    /// Fractions of the file at which the sample windows are placed.
    static let windowPositions: [Double] = [0.25, 0.5, 0.75]
    /// A shelf only counts as suspicious below this fraction of the sample
    /// rate; a genuine lossless file keeps content close to Nyquist, and
    /// resampling filters live above this line.
    static let losslessCeilingFraction = 0.45
    /// Minimum cliff (dB within 2 kHz of the edge) before a shelf is
    /// suspected. Natural spectra fall gradually; encoder shelves fall off a
    /// cliff to the coding floor.
    static let cliffThresholdDB = 25.0
    /// Well-known lossy encoder cutoffs (128k MP3 ≈ 16 kHz, V2/256k ≈ 19 to
    /// 19.5 kHz, 320k ≈ 20 to 20.5 kHz). An edge near one raises confidence.
    static let knownEncoderCeilingsHz: [Double] = [16000, 19000, 19500, 20000, 20500]
    /// How close (Hz) an edge must sit to a known ceiling for the bonus.
    static let ceilingToleranceHz = 500.0

    // MARK: - File analysis

    /// Decode sample windows from the file at `url` and score its provenance.
    ///
    /// - Parameters:
    ///   - url: A local file URL. Routed through `DecoderFactory`, so formats
    ///     AVFoundation refuses fall back to FFmpeg automatically.
    ///   - windowSeconds: Length of each sample window; the default suits
    ///     full-length tracks, tests use shorter windows on shorter files.
    /// - Throws: `AudioEngineError` when the file cannot be opened or decodes
    ///   to nothing.
    public static func analyze(
        url: URL,
        windowSeconds: Double = defaultWindowSeconds
    ) async throws -> ProvenanceVerdict {
        let log = AppLogger.make(.audio)
        let start = Date()
        log.debug("provenance.analyze.start", ["url": url.lastPathComponent])

        let decoder = try DecoderFactory.make(for: url)
        let sampleRate = decoder.sourceFormat.sampleRate
        let segments: [[Float]]
        do {
            segments = try await self.readWindows(decoder: decoder, windowSeconds: windowSeconds)
        } catch {
            await decoder.close()
            throw error
        }
        await decoder.close()

        guard segments.contains(where: { $0.count >= SpectralShelf.fftSize }) else {
            log.warning("provenance.analyze.empty", ["url": url.lastPathComponent])
            throw AudioEngineError.decoderFailure(codec: "pcm", underlying: URLError(.zeroByteResource))
        }

        let verdict = self.analyze(segments: segments, sampleRate: sampleRate)
        log.debug("provenance.analyze.end", [
            "url": url.lastPathComponent,
            "ms": -start.timeIntervalSinceNow * 1000,
            "suspected": verdict.suspected,
            "confidence": verdict.confidence,
        ])
        return verdict
    }

    // MARK: - PCM analysis

    /// Score pre-decoded mono segments. The file driver above is a thin
    /// decode loop over this; tests feed it synthesized PCM directly.
    ///
    /// - Returns: A clean (not suspected) verdict when the input is too short
    ///   or too low-rate to judge; suspicion always requires evidence.
    public static func analyze(segments: [[Float]], sampleRate: Double) -> ProvenanceVerdict {
        guard
            let spectrum = SpectralShelf.averagedSpectrumDB(segments: segments, sampleRate: sampleRate),
            let reading = SpectralShelf.reading(spectrumDB: spectrum, sampleRate: sampleRate) else {
            return self.cleanVerdict()
        }
        let losslessCeilingHz = sampleRate * self.losslessCeilingFraction
        guard reading.edgeHz < losslessCeilingHz, reading.cliffDropDB >= self.cliffThresholdDB else {
            return self.cleanVerdict()
        }
        let nearKnownCeiling = self.knownEncoderCeilingsHz.contains { ceiling in
            abs(ceiling - reading.edgeHz) <= self.ceilingToleranceHz
        }
        // Confidence: a floor for clearing the cliff threshold at all, plus
        // steepness (an 80 dB-over-threshold cliff saturates the term), plus
        // a bonus for sitting on a known encoder ceiling. Heuristic weights;
        // tune against real libraries before trusting them further.
        let steepness = min(1.0, max(0, (reading.cliffDropDB - self.cliffThresholdDB) / 80.0))
        let confidence = min(1.0, 0.3 + steepness * 0.55 + (nearKnownCeiling ? 0.25 : 0))
        return ProvenanceVerdict(
            suspected: true,
            confidence: confidence,
            shelfFrequencyHz: Int(reading.edgeHz.rounded()),
            analysedAt: Date()
        )
    }

    // MARK: - Private helpers

    private static func cleanVerdict() -> ProvenanceVerdict {
        ProvenanceVerdict(suspected: false, confidence: 0, shelfFrequencyHz: nil, analysedAt: Date())
    }

    /// Read the sample windows as mono segments. Files shorter than all three
    /// windows combined (or with unknown duration) are read once from the
    /// start instead of seeking.
    private static func readWindows(decoder: any Decoder, windowSeconds: Double) async throws -> [[Float]] {
        let duration = decoder.duration
        let sampleRate = decoder.sourceFormat.sampleRate
        guard sampleRate > 0 else { return [] }
        let windowFrames = Int(windowSeconds * sampleRate)
        guard duration > windowSeconds * Double(self.windowPositions.count) else {
            let whole = try await self.readMono(
                decoder: decoder,
                maxFrames: windowFrames * self.windowPositions.count
            )
            return [whole]
        }
        var segments: [[Float]] = []
        for fraction in self.windowPositions {
            try Task.checkCancellation()
            let windowStart = min(duration * fraction, max(0, duration - windowSeconds))
            try await decoder.seek(to: windowStart)
            try await segments.append(self.readMono(decoder: decoder, maxFrames: windowFrames))
        }
        return segments
    }

    /// Decode up to `maxFrames` frames from the decoder's current position,
    /// downmixed to mono by averaging channels.
    private static func readMono(decoder: any Decoder, maxFrames: Int) async throws -> [Float] {
        let format = decoder.sourceFormat
        let channels = Int(format.channelCount)
        let chunkFrames: AVAudioFrameCount = 65536
        guard channels > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AudioEngineError.decoderFailure(codec: "pcm", underlying: URLError(.unknown))
        }
        var mono: [Float] = []
        mono.reserveCapacity(maxFrames)
        while mono.count < maxFrames {
            try Task.checkCancellation()
            buffer.frameLength = 0
            let readFrames = try await decoder.read(into: buffer)
            guard readFrames > 0, let channelData = buffer.floatChannelData else { break }
            let usable = min(Int(readFrames), maxFrames - mono.count)
            if channels == 1 {
                mono.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: usable))
            } else {
                let scale = 1.0 / Float(channels)
                for frame in 0 ..< usable {
                    var sum: Float = 0
                    for channel in 0 ..< channels {
                        sum += channelData[channel][frame]
                    }
                    mono.append(sum * scale)
                }
            }
        }
        return mono
    }
}
