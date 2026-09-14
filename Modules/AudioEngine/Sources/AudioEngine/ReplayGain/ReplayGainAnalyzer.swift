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

        guard !leftSamples.isEmpty else {
            log.warning("rg.analyze.empty", [
                "url": url.lastPathComponent,
                "reportedLength": file.length,
            ])
            throw AudioEngineError.decoderFailure(codec: "pcm", underlying: URLError(.zeroByteResource))
        }

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
        let sourceFormat = file.processingFormat
        let chunkFrames: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else {
            throw AudioEngineError.decoderFailure(codec: "pcm", underlying: URLError(.unknown))
        }

        // More than two channels: fold every chunk to stereo at the file's own
        // rate with the converter the engine plays through, and measure the
        // fold (ADR-091 slice 2). Not BS.1770 multichannel weighting: that
        // measures the bed a surround system would play, but Bòcan plays the
        // fold, and the fold is what the listener hears at the volume the gain
        // sets. Channel order is also per container (MP4 gives C L R Ls Rs LFE,
        // E-AC-3 gives L C R Ls Rs LFE), so channels 0 and 1 of the raw buffer
        // are not left and right in general.
        let fold = sourceFormat.channelCount > 2 ? try self.stereoFold(for: sourceFormat) : nil
        let measuredChannels = fold == nil ? Int(sourceFormat.channelCount) : 2

        var leftSamples: [Float] = []
        var rightSamples: [Float] = []
        if file.length > 0 {
            leftSamples.reserveCapacity(Int(file.length))
            rightSamples.reserveCapacity(Int(file.length))
        }

        // Read until the decoder yields a short/zero-length buffer. We don't rely
        // on `file.framePosition < file.length` because some containers (notably
        // FLACs without a STREAMINFO sample count) report length 0 even though
        // the audio decodes fine.
        while true {
            try Task.checkCancellation()
            do {
                try file.read(into: buffer)
            } catch {
                // Treat decode errors mid-stream as end-of-file so we still get a
                // measurement from whatever decoded successfully.
                break
            }
            guard buffer.frameLength > 0 else { break }

            let measured = try self.folded(buffer, through: fold)
            let frames = Int(measured.frameLength)
            guard frames > 0 else { break }

            if let ch0 = measured.floatChannelData?[0] {
                leftSamples.append(contentsOf: UnsafeBufferPointer(start: ch0, count: frames))
            }
            if measuredChannels >= 2, let ch1 = measured.floatChannelData?[1] {
                rightSamples.append(contentsOf: UnsafeBufferPointer(start: ch1, count: frames))
            } else if let ch0 = measured.floatChannelData?[0] {
                // Mono: duplicate left channel into right for the stereo measurement
                rightSamples.append(contentsOf: UnsafeBufferPointer(start: ch0, count: frames))
            }
        }
        return (leftSamples, rightSamples)
    }

    /// The converter that folds `format` to stereo at its own sample rate.
    private static func stereoFold(for format: AVAudioFormat) throws -> FormatConverter {
        guard let stereo = StereoLayout.format(sampleRate: format.sampleRate) else {
            throw AudioEngineError.decoderFailure(codec: "pcm", underlying: URLError(.unknown))
        }
        return try FormatConverter(sourceFormat: format, targetFormat: stereo)
    }

    /// `buffer` folded through `fold`, or `buffer` itself when there is no fold.
    ///
    /// A fold failure is not a short file. The read loop swallows a mid-stream
    /// decode error as end-of-file, which is fine for a damaged tail; a fold
    /// that fails would instead silently measure only the chunks before it,
    /// so it is logged and propagated.
    private static func folded(_ buffer: AVAudioPCMBuffer, through fold: FormatConverter?) throws -> AVAudioPCMBuffer {
        guard let fold else { return buffer }
        do {
            guard let folded = try fold.convert(buffer) else { return buffer }
            return folded
        } catch {
            AppLogger.make(.audio).error("rg.fold.failed", [
                "channels": buffer.format.channelCount,
                "error": String(reflecting: error),
            ])
            throw error
        }
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
