@preconcurrency import AVFoundation
import CFFmpeg
import Foundation

// MARK: - FFmpegDecoder + sample-exact seek (#705)

/// A seek lands on the exact sample asked for, after the pre-roll the codec
/// needs.
///
/// `av_seek_frame` lands on a packet or page at or before the target, so the
/// decoder seeks to the target less the pre-roll, decodes from there, and
/// drops output by frame timestamp until the target sample. Dropping by
/// timestamp, not by a count of samples, keeps it right if a later FFmpeg
/// trims the pre-roll itself: trunk already injects that skip after a seek,
/// and the decoder moves the frame's timestamp past what it trims (which is
/// why `pkt_timebase` is set at open). A source whose frames carry no
/// timestamp keeps the behaviour from before: playback starts where the
/// demuxer landed.
extension FFmpegDecoder {
    /// `AV_NOPTS_VALUE` (not importable; the C macro casts).
    private static let noTimestamp = Int64.min

    /// Raw DSD (`AV_SAMPLE_FMT_DSD`, #706) is turned into PCM by
    /// swresample's FIR filter, which keeps the last 16 bytes of each channel
    /// (`DSD_FIFOSIZE` in libswresample/dsd2pcm.h). A seek resets it, so 16
    /// samples are decoded before the target to fill it again; without them
    /// the first output differs from a straight decode.
    static let dsdFilterPreroll: Int64 = 16

    /// Moves to `time`: the next read starts on that sample, decoded after
    /// the codec's pre-roll.
    ///
    /// - Throws: `AudioEngineError.seekOutOfRange` past the end or when the
    ///   demuxer cannot seek, and `decoderFailure` if the resampler cannot be
    ///   reset.
    public func seek(to time: TimeInterval) async throws {
        if self.duration > 0, time > self.duration + 0.001 {
            throw AudioEngineError.seekOutOfRange(requested: time, duration: self.duration)
        }
        let target = max(0, time)
        guard let fmtCtx = ctx.formatCtx,
              let stream = fmtCtx.pointee.streams?[Int(ctx.streamIndex)],
              let codecCtx = ctx.codecCtx else { return }

        let sampleRate = Int64(codecCtx.pointee.sample_rate)
        let preroll = Self.seekPreroll(stream: stream, codecCtx: codecCtx)
        let seekFrom = sampleRate > 0 ? max(0, target - TimeInterval(preroll) / TimeInterval(sampleRate)) : target

        let tbDen = stream.pointee.time_base.den
        let tbNum = stream.pointee.time_base.num
        let ts = (tbDen > 0 && tbNum > 0)
            ? Int64(seekFrom * TimeInterval(tbDen) / TimeInterval(tbNum))
            : Int64(seekFrom * TimeInterval(AV_TIME_BASE))

        let ret = av_seek_frame(fmtCtx, self.ctx.streamIndex, ts, AVSEEK_FLAG_BACKWARD)
        if ret < 0 {
            throw AudioEngineError.seekOutOfRange(requested: time, duration: self.duration)
        }
        avcodec_flush_buffers(codecCtx)
        // The resampler keeps state across calls (the DSD filter above);
        // swr_init closes and reopens it with the same settings.
        if let swrCtx = ctx.swrCtx {
            try Self.ffCheck(swr_init(swrCtx), codec: "FFmpeg/swr")
        }
        self.residualBuffer.removeAll()
        self.positionSeconds = target
        self.seekTargetSample = sampleRate > 0 ? Int64((target * TimeInterval(sampleRate)).rounded()) : nil
        self.nextFrameSample = nil
    }

    /// Samples to decode before the target: the larger of the stream's and
    /// the codec's pre-roll (FFmpeg 9.1's AAC decoder raises the codec value,
    /// Opus containers set the stream one), plus the DSD filter's history.
    static func seekPreroll(
        stream: UnsafeMutablePointer<AVStream>,
        codecCtx: UnsafeMutablePointer<AVCodecContext>
    ) -> Int64 {
        let streamPreroll = stream.pointee.codecpar.map { Int64($0.pointee.seek_preroll) } ?? 0
        let codecPreroll = Int64(codecCtx.pointee.seek_preroll)
        let filterPreroll = codecCtx.pointee.sample_fmt == AV_SAMPLE_FMT_DSD ? self.dsdFilterPreroll : 0
        return max(0, streamPreroll, codecPreroll) + filterPreroll
    }

    /// How many leading samples of a frame fall before the seek target.
    /// Zero when the frame starts at or after it; the whole frame when it
    /// ends at or before it.
    static func leadingSamplesToDrop(frameStart: Int64, frameCount: Int, target: Int64) -> Int {
        guard frameCount > 0 else { return 0 }
        return Int(min(max(target - frameStart, 0), Int64(frameCount)))
    }

    /// What `receiveConverted` got back from the codec for the packets sent
    /// so far.
    enum ReceiveOutcome {
        case samples([Float])
        case needPacket
        case ended
    }

    /// Converts `frame` and, while a seek is settling, drops the samples
    /// before its target. Every frame goes through the resampler, dropped or
    /// not, so its state is warm when the first kept sample arrives.
    func convertTrimmingToSeekTarget(
        _ frame: UnsafeMutablePointer<AVFrame>,
        swrCtx: OpaquePointer
    ) throws -> [Float] {
        let converted = try self.convertFrame(frame, swrCtx: swrCtx)
        guard let target = self.seekTargetSample else { return converted }
        let channels = Int(self.outChannels)
        let count = converted.count / channels

        guard let start = self.frameStartSample(frame) else {
            // No timestamp and none to carry on from: keep it, as before #705.
            self.endSeekTrim()
            return converted
        }
        self.nextFrameSample = start + Int64(count)
        let drop = Self.leadingSamplesToDrop(frameStart: start, frameCount: count, target: target)
        if drop < count {
            self.endSeekTrim()
        }
        return drop == 0 ? converted : Array(converted.dropFirst(drop * channels))
    }

    private func endSeekTrim() {
        self.seekTargetSample = nil
        self.nextFrameSample = nil
    }

    /// The frame's first sample on the stream's timeline: its timestamp
    /// when it has one, else where the previous frame ended.
    private func frameStartSample(_ frame: UnsafeMutablePointer<AVFrame>) -> Int64? {
        let timestamp = frame.pointee.best_effort_timestamp
        guard timestamp != Self.noTimestamp,
              let stream = ctx.formatCtx?.pointee.streams?[Int(ctx.streamIndex)],
              let codecCtx = ctx.codecCtx,
              codecCtx.pointee.sample_rate > 0 else {
            return self.nextFrameSample
        }
        let perSample = AVRational(num: 1, den: codecCtx.pointee.sample_rate)
        return av_rescale_q(timestamp, stream.pointee.time_base, perSample)
    }
}
