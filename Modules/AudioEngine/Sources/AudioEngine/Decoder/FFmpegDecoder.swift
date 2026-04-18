// @preconcurrency: AVAudioPCMBuffer/AVAudioFormat lack Sendable; safe because
// FFmpegDecoder is the sole owner of its buffers.
// TODO: Remove once AVFoundation adopts Sendable annotations.
@preconcurrency import AVFoundation
import CFFmpeg
import Foundation
import Observability

// MARK: - Swift constants for non-importable FFmpeg macros

/// `AV_NOPTS_VALUE` — the sentinel for "no presentation timestamp".
private let AV_NOPTS_VALUE_SWIFT = Int64(bitPattern: 0x8000_0000_0000_0000)

/// Equivalent of C's `AVERROR(e)`: negates the POSIX error code.
private func AVERROR_POSIX(_ code: Int32) -> Int32 {
    -code
}

/// `AVERROR_EOF` — end of stream (not importable as it uses C casts).
private let AVERROR_EOF_SWIFT: Int32 = -541_478_725

/// macOS `EAGAIN`.
private let EAGAIN_CODE: Int32 = 35

// MARK: - FFmpegDecoder

public actor FFmpegDecoder: Decoder {
    // MARK: - Private C-context wrapper

    private final class FFContext {
        var formatCtx: UnsafeMutablePointer<AVFormatContext>?
        var codecCtx: UnsafeMutablePointer<AVCodecContext>?
        var swrCtx: OpaquePointer?
        var streamIndex: Int32 = -1
        var packet: UnsafeMutablePointer<AVPacket>?
        var frame: UnsafeMutablePointer<AVFrame>?

        init() {
            self.packet = av_packet_alloc()
            self.frame = av_frame_alloc()
        }

        deinit {
            av_packet_free(&packet)
            av_frame_free(&frame)
            var swr = swrCtx
            swr_free(&swr)
            var codec = codecCtx
            avcodec_free_context(&codec)
            var fmt = formatCtx
            avformat_close_input(&fmt)
        }
    }

    // MARK: - State

    private let ctx: FFContext
    private let log = AppLogger.make(.audio)
    private let url: URL

    public nonisolated let sourceFormat: AVAudioFormat
    public nonisolated let duration: TimeInterval

    private var _position: TimeInterval = 0
    private var residualBuffer: [Float] = []
    private let outChannels: Int32 = 2

    // MARK: - Init

    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioEngineError.fileNotFound(url)
        }

        let ctx = FFContext()
        self.ctx = ctx
        self.url = url

        let openRet = avformat_open_input(&ctx.formatCtx, url.path, nil, nil)
        if openRet < 0 {
            throw AudioEngineError.accessDenied(url, underlying: ffError(openRet))
        }

        let infoRet = avformat_find_stream_info(ctx.formatCtx, nil)
        if infoRet < 0 {
            throw AudioEngineError.decoderFailure(codec: "FFmpeg", underlying: ffError(infoRet))
        }

        let streamIdx = av_find_best_stream(ctx.formatCtx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        if streamIdx < 0 {
            throw AudioEngineError.decoderFailure(
                codec: "FFmpeg", underlying: FFmpegInternalError.noStream
            )
        }
        ctx.streamIndex = streamIdx

        guard let stream = ctx.formatCtx?.pointee.streams?[Int(streamIdx)],
              let codecParams = stream.pointee.codecpar else
        {
            throw AudioEngineError.decoderFailure(
                codec: "FFmpeg", underlying: FFmpegInternalError.noStream
            )
        }

        guard let codec = avcodec_find_decoder(codecParams.pointee.codec_id) else {
            throw AudioEngineError.decoderFailure(
                codec: "FFmpeg", underlying: FFmpegInternalError.noDecoder
            )
        }

        guard let codecCtx = avcodec_alloc_context3(codec) else {
            throw AudioEngineError.decoderFailure(
                codec: "FFmpeg", underlying: FFmpegInternalError.alloc
            )
        }
        ctx.codecCtx = codecCtx

        let copyRet = avcodec_parameters_to_context(codecCtx, codecParams)
        if copyRet < 0 {
            throw AudioEngineError.decoderFailure(codec: "FFmpeg", underlying: ffError(copyRet))
        }

        let codecOpenRet = avcodec_open2(codecCtx, codec, nil)
        if codecOpenRet < 0 {
            throw AudioEngineError.decoderFailure(
                codec: "FFmpeg", underlying: ffError(codecOpenRet)
            )
        }

        let sampleRate = Double(codecCtx.pointee.sample_rate)

        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, 2)

        var swrCtx: OpaquePointer?
        let swrRet = swr_alloc_set_opts2(
            &swrCtx,
            &outLayout,
            AV_SAMPLE_FMT_FLTP,
            Int32(sampleRate),
            &codecCtx.pointee.ch_layout,
            codecCtx.pointee.sample_fmt,
            Int32(sampleRate),
            0, nil
        )
        av_channel_layout_uninit(&outLayout)

        if swrRet < 0 {
            throw AudioEngineError.decoderFailure(codec: "FFmpeg/swr", underlying: ffError(swrRet))
        }
        let swrInitRet = swr_init(swrCtx)
        if swrInitRet < 0 {
            swr_free(&swrCtx)
            throw AudioEngineError.decoderFailure(
                codec: "FFmpeg/swr", underlying: ffError(swrInitRet)
            )
        }
        ctx.swrCtx = swrCtx

        // Duration from stream or container.
        let tbNum = stream.pointee.time_base.num
        let tbDen = stream.pointee.time_base.den
        let rawDur = stream.pointee.duration
        if rawDur != AV_NOPTS_VALUE_SWIFT, tbDen > 0 {
            self.duration = TimeInterval(rawDur) * TimeInterval(tbNum) / TimeInterval(tbDen)
        } else if let fmtCtx = ctx.formatCtx,
                  fmtCtx.pointee.duration != AV_NOPTS_VALUE_SWIFT
        {
            self.duration = TimeInterval(fmtCtx.pointee.duration) / TimeInterval(AV_TIME_BASE)
        } else {
            self.duration = 0
        }

        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)!
        self.sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }

    // MARK: - Decoder

    public var position: TimeInterval {
        self._position
    }

    public func read(into buffer: AVAudioPCMBuffer) async throws -> AVAudioFrameCount {
        try Task.checkCancellation()
        let capacity = Int(buffer.frameCapacity)
        var totalFrames = 0

        totalFrames += self.drainResidual(into: buffer, startFrame: 0, capacity: capacity)

        while totalFrames < capacity {
            try Task.checkCancellation()
            let raw = try readNextFrames()
            guard !raw.isEmpty else { break }

            let overflow = self.copyInterleaved(
                raw, into: buffer, startFrame: totalFrames, capacity: capacity
            )
            totalFrames += (raw.count - overflow.count) / Int(self.outChannels)
            if !overflow.isEmpty { self.residualBuffer = overflow
                break
            }
        }

        buffer.frameLength = AVAudioFrameCount(totalFrames)
        if self.sourceFormat.sampleRate > 0 {
            self._position += TimeInterval(totalFrames) / self.sourceFormat.sampleRate
        }
        return buffer.frameLength
    }

    public func seek(to time: TimeInterval) async throws {
        if self.duration > 0 && time > self.duration + 0.001 {
            throw AudioEngineError.seekOutOfRange(requested: time, duration: self.duration)
        }
        let target = max(0, time)
        guard let fmtCtx = ctx.formatCtx,
              let stream = fmtCtx.pointee.streams?[Int(ctx.streamIndex)] else { return }

        let tbDen = stream.pointee.time_base.den
        let tbNum = stream.pointee.time_base.num
        let ts = (tbDen > 0 && tbNum > 0)
            ? Int64(target * TimeInterval(tbDen) / TimeInterval(tbNum))
            : Int64(target * TimeInterval(AV_TIME_BASE))

        let ret = av_seek_frame(ctx.formatCtx, self.ctx.streamIndex, ts, AVSEEK_FLAG_BACKWARD)
        if ret < 0 {
            throw AudioEngineError.seekOutOfRange(requested: time, duration: self.duration)
        }
        avcodec_flush_buffers(self.ctx.codecCtx)
        self.residualBuffer.removeAll()
        self._position = target
    }

    public func close() async {
        self.log.debug("ffmpeg.decoder.closed", ["url": self.url.lastPathComponent])
    }

    // MARK: - Private decode helpers

    private func readNextFrames() throws -> [Float] {
        guard let fmtCtx = ctx.formatCtx,
              let codecCtx = ctx.codecCtx,
              let swrCtx = ctx.swrCtx,
              let pkt = ctx.packet,
              let frm = ctx.frame else { return [] }

        var result: [Float] = []

        outer: while true {
            let readRet = av_read_frame(fmtCtx, pkt)

            if readRet == AVERROR_EOF_SWIFT {
                avcodec_send_packet(codecCtx, nil)
                try self.drainCodec(codecCtx, swrCtx: swrCtx, frame: frm, into: &result)
                break
            }
            if readRet < 0 {
                throw AudioEngineError.decoderFailure(
                    codec: "FFmpeg", underlying: ffError(readRet)
                )
            }
            defer { av_packet_unref(pkt) }

            guard pkt.pointee.stream_index == self.ctx.streamIndex else { continue }

            let sendRet = avcodec_send_packet(codecCtx, pkt)
            if sendRet < 0, sendRet != AVERROR_POSIX(EAGAIN_CODE) { continue }

            inner: while true {
                let recvRet = avcodec_receive_frame(codecCtx, frm)
                if recvRet == AVERROR_POSIX(EAGAIN_CODE) { continue outer }
                if recvRet == AVERROR_EOF_SWIFT { break outer }
                if recvRet < 0 { break inner }

                let converted = try convertFrame(frm, swrCtx: swrCtx)
                av_frame_unref(frm)
                result.append(contentsOf: converted)
                break outer
            }
        }
        return result
    }

    private func drainCodec(
        _ codecCtx: UnsafeMutablePointer<AVCodecContext>,
        swrCtx: OpaquePointer,
        frame: UnsafeMutablePointer<AVFrame>,
        into result: inout [Float]
    ) throws {
        while true {
            let ret = avcodec_receive_frame(codecCtx, frame)
            if ret == AVERROR_EOF_SWIFT || ret == AVERROR_POSIX(EAGAIN_CODE) { break }
            if ret < 0 { break }
            let converted = try convertFrame(frame, swrCtx: swrCtx)
            av_frame_unref(frame)
            result.append(contentsOf: converted)
        }
    }

    private func convertFrame(
        _ frame: UnsafeMutablePointer<AVFrame>,
        swrCtx: OpaquePointer
    ) throws -> [Float] {
        let nbSamples = Int(frame.pointee.nb_samples)
        guard nbSamples > 0 else { return [] }

        let outCount = nbSamples + 256
        let byteCount = outCount * MemoryLayout<Float>.size

        let ch0 = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        let ch1 = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        defer { ch0.deallocate()
            ch1.deallocate()
        }

        var outPtrs: [UnsafeMutablePointer<UInt8>?] = [
            ch0.assumingMemoryBound(to: UInt8.self),
            ch1.assumingMemoryBound(to: UInt8.self),
        ]

        let totalFrames: Int32 = outPtrs.withUnsafeMutableBufferPointer { ptr in
            // extended_data is UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>;
            // swr_convert expects UnsafePointer<UnsafePointer<UInt8>?> — same bit pattern.
            let inData = unsafeBitCast(
                frame.pointee.extended_data,
                to: UnsafePointer<UnsafePointer<UInt8>?>?.self
            )
            return swr_convert(swrCtx, ptr.baseAddress, Int32(outCount), inData, Int32(nbSamples))
        }

        if totalFrames < 0 {
            throw AudioEngineError.decoderFailure(
                codec: "FFmpeg/swr", underlying: ffError(totalFrames)
            )
        }

        let n = Int(totalFrames)
        let f0 = ch0.assumingMemoryBound(to: Float.self)
        let f1 = ch1.assumingMemoryBound(to: Float.self)
        var result = [Float](repeating: 0, count: n * 2)
        for i in 0 ..< n {
            result[i * 2] = f0[i]
            result[i * 2 + 1] = f1[i]
        }
        return result
    }

    private func copyInterleaved(
        _ interleaved: [Float],
        into buffer: AVAudioPCMBuffer,
        startFrame: Int,
        capacity: Int
    ) -> [Float] {
        let frames = min(interleaved.count / Int(self.outChannels), capacity - startFrame)
        guard frames > 0, let ch = buffer.floatChannelData else { return [] }
        for c in 0 ..< Int(self.outChannels) {
            for i in 0 ..< frames {
                ch[c][startFrame + i] = interleaved[i * Int(self.outChannels) + c]
            }
        }
        return Array(interleaved.dropFirst(frames * Int(self.outChannels)))
    }

    private func drainResidual(
        into buffer: AVAudioPCMBuffer,
        startFrame: Int,
        capacity: Int
    ) -> Int {
        guard !self.residualBuffer.isEmpty else { return 0 }
        let overflow = self.copyInterleaved(
            self.residualBuffer, into: buffer, startFrame: startFrame, capacity: capacity
        )
        let written = (residualBuffer.count - overflow.count) / Int(self.outChannels)
        self.residualBuffer = overflow
        return written
    }
}

// MARK: - Private helpers

private func ffError(_ code: Int32) -> Error {
    var buf = [CChar](repeating: 0, count: 256)
    av_strerror(code, &buf, buf.count)
    let msg = buf.withUnsafeBufferPointer {
        String(decoding: $0.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }.trimmingCharacters(in: .controlCharacters)
    return FFmpegInternalError.code(code, msg)
}

private enum FFmpegInternalError: Error, LocalizedError {
    case code(Int32, String)
    case noStream
    case noDecoder
    case alloc

    var errorDescription: String? {
        switch self {
        case let .code(_, msg): msg
        case .noStream: "No audio stream found"
        case .noDecoder: "No decoder found for codec"
        case .alloc: "Memory allocation failed"
        }
    }
}
