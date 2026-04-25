@preconcurrency import AVFoundation
import Foundation
import Observability

// MARK: - ReplayGainResult

/// The computed ReplayGain values for a single track (ReplayGain 2.0, target −18 LUFS).
public struct ReplayGainResult: Sendable {
    /// Track gain in dB (negative means the track is louder than −18 LUFS).
    public let trackGainDB: Double
    /// True-peak in linear amplitude.
    public let trackPeakLinear: Double
    /// Integrated LUFS before gain correction.
    public let integratedLUFS: Double

    public init(integratedLUFS: Double, truePeakLinear: Double) {
        self.integratedLUFS = integratedLUFS
        self.trackGainDB = -18.0 - integratedLUFS // ReplayGain 2.0: target −18 LUFS
        self.trackPeakLinear = truePeakLinear
    }
}

// MARK: - ReplayGainAnalyzer

/// Decodes an audio file and measures its ReplayGain (EBU R128) values.
///
/// Uses `AVAudioFile` for decoding; all work runs on the calling task's thread.
/// Check `Task.isCancelled` between chunks to respect cooperative cancellation.
///
/// Album mode: pass multiple `ReplayGainResult` values to `albumGain(from:)` to
/// compute the album-level gain from a set of pre-measured tracks.
public struct ReplayGainAnalyzer: Sendable {
    // MARK: - Constants

    /// Target integrated loudness for ReplayGain 2.0.
    public static let targetLUFS: Double = -18.0

    // MARK: - Single-track analysis

    /// Decode and measure the ReplayGain values for the audio file at `url`.
    ///
    /// - Parameter url: A local file URL.
    /// - Returns: `ReplayGainResult` for the track.
    /// - Throws: `AudioEngineError.decoderFailure` if the file cannot be opened.
    public static func analyze(url: URL) async throws -> ReplayGainResult {
        let log = AppLogger.make(.audio)
        let start = Date()
        log.debug("rg.analyze.start", ["url": url.lastPathComponent])

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioEngineError.decoderFailure(codec: "unknown", underlying: error)
        }

        let (leftSamples, rightSamples) = try await readSamples(from: file)

        let r128 = EBUR128.measure(
            leftSamples: leftSamples,
            rightSamples: rightSamples,
            sampleRate: file.processingFormat.sampleRate
        )
        let result = ReplayGainResult(integratedLUFS: r128.integratedLUFS, truePeakLinear: r128.truePeakLinear)
        log.debug("rg.analyze.end", [
            "url": url.lastPathComponent,
            "ms": -start.timeIntervalSinceNow * 1000,
            "lufs": r128.integratedLUFS,
            "gain": result.trackGainDB,
        ])
        return result
    }

    // MARK: - Private helpers

    private static func readSamples(from file: AVAudioFile) async throws -> ([Float], [Float]) {
        let channelCount = Int(file.processingFormat.channelCount)
        let chunkFrames: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
            throw AudioEngineError.decoderFailure(codec: "pcm", underlying: URLError(.unknown))
        }

        var leftSamples: [Float] = []
        var rightSamples: [Float] = []
        leftSamples.reserveCapacity(Int(file.length))
        rightSamples.reserveCapacity(Int(file.length))

        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }

            if let ch0 = buffer.floatChannelData?[0] {
                leftSamples.append(contentsOf: UnsafeBufferPointer(start: ch0, count: frames))
            }
            if channelCount >= 2, let ch1 = buffer.floatChannelData?[1] {
                rightSamples.append(contentsOf: UnsafeBufferPointer(start: ch1, count: frames))
            } else if let ch0 = buffer.floatChannelData?[0] {
                // Mono: duplicate left channel into right for the stereo measurement
                rightSamples.append(contentsOf: UnsafeBufferPointer(start: ch0, count: frames))
            }
        }
        return (leftSamples, rightSamples)
    }

    // MARK: - Album-level aggregation

    /// Compute the album gain from a set of track measurements.
    ///
    /// Album gain uses the power-mean of all tracks' loudness values, so quiet tracks
    /// don't drag the whole album up.
    ///
    /// - Parameter results: Pre-computed track measurements.
    /// - Returns: `(albumGainDB, albumPeakLinear)` or `nil` if `results` is empty.
    public static func albumGain(from results: [ReplayGainResult]) -> (gainDB: Double, peakLinear: Double)? {
        guard !results.isEmpty else { return nil }
        // Power-mean of integrated loudness values (equivalent to summing mean-squares)
        let meanPower = results.map { pow(10.0, $0.integratedLUFS / 10.0) }.reduce(0, +) / Double(results.count)
        let albumLUFS = 10.0 * log10(meanPower)
        let albumGainDB = self.targetLUFS - albumLUFS
        let albumPeak = results.map(\.trackPeakLinear).max() ?? 0
        return (gainDB: albumGainDB, peakLinear: albumPeak)
    }
}
