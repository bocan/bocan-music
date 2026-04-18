@preconcurrency import AVFoundation
import Foundation
import Observability

/// Converts an `AVAudioPCMBuffer` from any source format to the canonical
/// engine format (Float32, non-interleaved, stereo, target sample rate).
///
/// Create one converter per source format. If the source format already matches
/// the target, conversion is a no-op copy.
public struct FormatConverter: Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let log = AppLogger.make(.audio)

    /// - Parameters:
    ///   - sourceFormat: The format produced by the decoder.
    ///   - targetFormat: The canonical engine format.
    /// - Throws: `AudioEngineError.formatConversionFailure` if a converter cannot be created.
    public init(sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat) throws {
        guard let conv = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioEngineError.formatConversionFailure(
                from: sourceFormat,
                to: targetFormat
            )
        }
        self.converter = conv
        self.outputFormat = targetFormat
    }

    /// Convert `sourceBuffer` to the target format.
    ///
    /// - Returns: A new buffer in `targetFormat`, or `nil` if the source had 0 frames.
    /// - Throws: `AudioEngineError.formatConversionFailure` on error.
    public func convert(_ sourceBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard sourceBuffer.frameLength > 0 else { return nil }

        let capacity = AVAudioFrameCount(
            Double(sourceBuffer.frameLength) *
                (self.outputFormat.sampleRate / sourceBuffer.format.sampleRate)
        ) + 1

        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            throw AudioEngineError.formatConversionFailure(
                from: sourceBuffer.format,
                to: self.outputFormat
            )
        }

        var convError: NSError?
        var didProvide = false

        let status = self.converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if didProvide {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvide = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if status == .error {
            throw AudioEngineError.formatConversionFailure(
                from: sourceBuffer.format,
                to: self.outputFormat
            )
        }

        return outBuffer
    }
}
