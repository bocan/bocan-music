// @preconcurrency: AVAudioFormat/AVAudioPCMBuffer lack Sendable; a PumpSource
// is owned by exactly one BufferPump at a time and only touched on its executor.
// Remove once AVFoundation adopts Sendable annotations (FB13119463).
@preconcurrency import AVFoundation
import Foundation

// MARK: - PumpSource

/// One track as the buffer pump reads it: the decoder, the converter that
/// brings its audio to the canonical output format, and running frame counts
/// (ADR-095, slice 2a).
///
/// Split out of `BufferPump` so a pump can hold more than one source: during a
/// crossfade (slice 2b) it reads the outgoing and the incoming track side by
/// side. Owned by exactly one pump at a time, and only used on that pump's
/// executor, which is what makes the `@unchecked Sendable` safe: a source is
/// built on one actor and handed over once, never shared.
///
/// Read and convert are separate steps on purpose. The pump reports the two
/// failures differently (`pump.read.failed` reaches the engine through
/// `onError`; `pump.convert.failed` only ends the feed loop), so a combined
/// call would hide which step failed.
final class PumpSource: @unchecked Sendable {
    // MARK: - Configuration

    let decoder: any Decoder

    /// The canonical output format every buffer leaves `convert` in.
    let outputFormat: AVAudioFormat

    /// Format used to allocate intermediate decode buffers. Always a format the
    /// decoder can fill: equal to `decoder.sourceFormat` whenever `converter`
    /// exists, and to `outputFormat` (which then matches the source in rate and
    /// channel count) when it does not. Asking `AVAudioFile` to read a 5.1 file
    /// into a stereo buffer is a read error, not a fold (#515).
    let pumpFormat: AVAudioFormat

    /// Non-nil when `decoder.sourceFormat` differs from `outputFormat` in sample
    /// rate or channel count. `AVFoundationDecoder` handles SRC internally via
    /// AVAudioFile, but FFmpegDecoder does not; without this converter it would
    /// fill hardware-rate buffers with source-rate samples, causing playback at
    /// the wrong speed and pitch. The channel-count case is the stereo fold:
    /// both decoders hand over the file's own channels above two (ADR-091,
    /// #522), and this one converter folds every route the same way.
    private let converter: FormatConverter?

    /// When non-nil, the source ends after this many decoder-native frames.
    /// Enforces the end of an `AudioEngine.setSegment` segment without relying
    /// on the underlying decoder reaching true EOF (kept per ADR-087 as a
    /// primitive; no caller since the virtual-track columns went).
    let maxFrames: AVAudioFrameCount?

    // MARK: - Running counts

    /// Decoder-native frames read since the source started or last seeked.
    /// The segment budget is measured against this.
    private(set) var framesRead: AVAudioFrameCount = 0

    /// Output-rate frames produced by `convert` since the source started or
    /// last seeked.
    private(set) var outputFramesProduced: AVAudioFramePosition = 0

    /// The output-rate frame the source started from: 0, or the target of
    /// the last seek. Added to `outputFramesProduced` for an absolute position.
    private(set) var startOutputFrame: AVAudioFramePosition = 0

    /// Converted frames the pump has not yet scheduled. Empty except around a
    /// crossfade, where the pump cuts buffers at exact frames (ADR-095).
    let pending: PCMFrameQueue

    // MARK: - Init

    init(decoder: any Decoder, outputFormat: AVAudioFormat, maxDuration: TimeInterval? = nil) throws {
        self.decoder = decoder
        self.outputFormat = outputFormat
        self.pending = PCMFrameQueue(format: outputFormat)
        // The budget counts decoder-native frames: the feed loop compares it
        // against framesRead BEFORE resampling. Computing it from the output
        // rate overshot a CUE boundary by the rate ratio (a 44.1k file on a
        // 48k device played ~8.8% past the segment end, audibly bleeding the
        // next track's opening before the end signal fired).
        self.maxFrames = maxDuration.map { AVAudioFrameCount($0 * decoder.sourceFormat.sampleRate) }
        let source = decoder.sourceFormat
        if source.sampleRate != outputFormat.sampleRate || source.channelCount != outputFormat.channelCount {
            self.converter = try FormatConverter(sourceFormat: source, targetFormat: outputFormat)
            self.pumpFormat = source
        } else {
            self.converter = nil
            self.pumpFormat = outputFormat
        }
    }

    /// Whether this source converts (resamples or folds) before scheduling.
    var hasConverter: Bool {
        self.converter != nil
    }

    // MARK: - Position

    /// The output-rate frame, counted from the start of the file, that the
    /// next scheduled frame of this source will play. Frames still in
    /// `pending` are not scheduled yet, so they do not count.
    var scheduledPosition: AVAudioFramePosition {
        self.startOutputFrame + self.outputFramesProduced - AVAudioFramePosition(self.pending.count)
    }

    /// The source's length in output-rate frames, from the decoder's
    /// `duration`. An estimate for some containers (a VBR MP3 without a Xing
    /// header), so a crossfade built on it must cope with the real end
    /// arriving early or late (ADR-095, Gotchas).
    var estimatedTotalOutputFrames: AVAudioFramePosition {
        AVAudioFramePosition((self.decoder.duration * self.outputFormat.sampleRate).rounded())
    }

    // MARK: - Reading

    /// Decoder-native frames left before the segment ends, or `nil` when the
    /// source has no segment budget.
    var remainingSegmentFrames: AVAudioFrameCount? {
        self.maxFrames.map { $0 - self.framesRead }
    }

    /// A fresh decode buffer in `pumpFormat` holding `duration` seconds.
    func makeReadBuffer(duration: TimeInterval) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(self.pumpFormat.sampleRate * duration)
        return AVAudioPCMBuffer(pcmFormat: self.pumpFormat, frameCapacity: capacity)
    }

    /// Fill `buffer` from the decoder. Returns `0` at end-of-stream.
    func read(into buffer: AVAudioPCMBuffer) async throws -> AVAudioFrameCount {
        let frames = try await self.decoder.read(into: buffer)
        self.framesRead += frames
        return frames
    }

    /// `buffer` in the canonical output format: unchanged when no conversion
    /// is needed, otherwise resampled and/or folded to stereo. `nil` for empty
    /// input.
    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        let converted: AVAudioPCMBuffer? = if let converter = self.converter {
            try converter.convert(buffer)
        } else {
            buffer
        }
        if let converted {
            self.outputFramesProduced += AVAudioFramePosition(converted.frameLength)
        }
        return converted
    }

    // MARK: - Seeking

    /// Reseek the decoder to `time` and restart the running counts from there.
    /// Frames still pending belong to the old position and are dropped.
    func seek(to time: TimeInterval) async throws {
        try await self.decoder.seek(to: time)
        self.framesRead = 0
        self.outputFramesProduced = 0
        self.startOutputFrame = AVAudioFramePosition((time * self.outputFormat.sampleRate).rounded())
        self.pending.removeAll()
    }
}
