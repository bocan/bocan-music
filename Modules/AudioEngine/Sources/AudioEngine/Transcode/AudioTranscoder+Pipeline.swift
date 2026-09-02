import CFFmpeg
import Foundation

// MARK: - FFmpeg sentinels

// C macros the Swift importer drops, re-declared as constants; the same
// idiom (and values) as FFmpegDecoder.swift.

/// Negates a POSIX error code, equivalent to the C macro `AVERROR(e)`.
private func averrorPosix(_ code: Int32) -> Int32 {
    -code
}

/// `AVERROR_EOF` — end of stream.
private let avErrorEof: Int32 = -541_478_725

/// macOS `EAGAIN` — resource temporarily unavailable.
private let eagainCode: Int32 = 35

/// `AVFMT_GLOBALHEADER` — the muxer wants codec extradata in the file header.
private let avfmtGlobalHeader: Int32 = 0x0040

/// `AV_CODEC_FLAG_GLOBAL_HEADER` (1 << 22).
private let avCodecFlagGlobalHeader: Int32 = 1 << 22

/// `AVIO_FLAG_WRITE`.
private let avioFlagWrite: Int32 = 2

/// `AV_DICT_IGNORE_SUFFIX` — iterate every dictionary entry.
private let avDictIgnoreSuffix: Int32 = 2

// MARK: - Pipeline

extension AudioTranscoder {
    /// Opens the source and configures the decoder, mirroring
    /// `FFmpegDecoder.openAndConfigure` (local files only; no HTTP here).
    func openInput(_ ctx: TranscodeContext, source: URL) throws {
        let openRet = avformat_open_input(&ctx.inFormatCtx, source.path, nil, nil)
        if openRet < 0 {
            throw AudioEngineError.accessDenied(source, underlying: ffError(openRet))
        }
        try checkDecode(avformat_find_stream_info(ctx.inFormatCtx, nil))

        let streamIdx = av_find_best_stream(ctx.inFormatCtx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard streamIdx >= 0 else {
            throw AudioEngineError.decoderFailure(codec: "FFmpeg", underlying: TranscodeInternalError.noStream)
        }
        ctx.streamIndex = streamIdx

        guard let stream = ctx.inFormatCtx?.pointee.streams?[Int(streamIdx)],
              let codecParams = stream.pointee.codecpar else {
            throw AudioEngineError.decoderFailure(codec: "FFmpeg", underlying: TranscodeInternalError.noStream)
        }
        guard let codec = avcodec_find_decoder(codecParams.pointee.codec_id) else {
            throw AudioEngineError.decoderFailure(codec: "FFmpeg", underlying: TranscodeInternalError.noDecoder)
        }
        guard let decodeCtx = avcodec_alloc_context3(codec) else {
            throw AudioEngineError.decoderFailure(codec: "FFmpeg", underlying: TranscodeInternalError.alloc)
        }
        // Parked before the throwing calls so a failure is still covered by
        // TranscodeContext.deinit (#295).
        ctx.decodeCtx = decodeCtx
        try checkDecode(avcodec_parameters_to_context(decodeCtx, codecParams))
        try checkDecode(avcodec_open2(decodeCtx, codec, nil))

        ctx.inSampleRate = decodeCtx.pointee.sample_rate
        ctx.outChannels = min(decodeCtx.pointee.ch_layout.nb_channels, 2)
        guard ctx.inSampleRate > 0, ctx.outChannels > 0 else {
            throw AudioEngineError.decoderFailure(codec: "FFmpeg", underlying: TranscodeInternalError.noStream)
        }
    }

    /// Configures the encoder, resampler, FIFO, and muxer, and writes the
    /// container header (metadata included).
    func openOutput(
        _ ctx: TranscodeContext,
        destination: URL,
        preset: TranscodePreset,
        metadata: [String: String]
    ) throws {
        guard let decodeCtx = ctx.decodeCtx else {
            throw AudioEngineError.encoderFailure(codec: preset.encoderName, underlying: TranscodeInternalError.alloc)
        }
        ctx.outSampleRate = preset.outputSampleRate(forSourceRate: ctx.inSampleRate)
        // Hardcoded per encoder rather than read from the deprecated
        // AVCodec.sample_fmts list: libmp3lame takes planar s16, libopus
        // takes packed s16.
        let sampleFmt = preset.fileExtension == "mp3" ? AV_SAMPLE_FMT_S16P : AV_SAMPLE_FMT_S16

        // Muxer first (guessed from the destination extension), so a bad
        // path fails before any codec work.
        let allocRet = avformat_alloc_output_context2(&ctx.outFormatCtx, nil, nil, destination.path)
        guard allocRet >= 0, let outFmt = ctx.outFormatCtx else {
            throw AudioEngineError.encoderFailure(codec: preset.encoderName, underlying: ffError(allocRet))
        }

        let wantsGlobalHeader = (outFmt.pointee.oformat.pointee.flags & avfmtGlobalHeader) != 0
        try self.makeEncoderContext(ctx, preset: preset, sampleFmt: sampleFmt, globalHeader: wantsGlobalHeader)
        guard let encodeCtx = ctx.encodeCtx else {
            throw AudioEngineError.encoderFailure(codec: preset.encoderName, underlying: TranscodeInternalError.alloc)
        }

        // Resampler: source layout/format/rate to encoder layout/format/rate.
        let swrRet = swr_alloc_set_opts2(
            &ctx.swrCtx,
            &encodeCtx.pointee.ch_layout,
            sampleFmt,
            ctx.outSampleRate,
            &decodeCtx.pointee.ch_layout,
            decodeCtx.pointee.sample_fmt,
            ctx.inSampleRate,
            0,
            nil
        )
        try checkEncode(swrRet, preset: preset)
        try checkEncode(swr_init(ctx.swrCtx), preset: preset)

        ctx.fifo = av_audio_fifo_alloc(sampleFmt, ctx.outChannels, 4096)
        guard ctx.fifo != nil else {
            throw AudioEngineError.encoderFailure(codec: preset.encoderName, underlying: TranscodeInternalError.alloc)
        }

        guard let stream = avformat_new_stream(outFmt, nil) else {
            throw AudioEngineError.encoderFailure(codec: preset.encoderName, underlying: TranscodeInternalError.alloc)
        }
        stream.pointee.time_base = encodeCtx.pointee.time_base
        try checkEncode(avcodec_parameters_from_context(stream.pointee.codecpar, encodeCtx), preset: preset)

        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
            av_dict_set(&outFmt.pointee.metadata, key, value, 0)
        }
        try checkEncode(avio_open(&outFmt.pointee.pb, destination.path, avioFlagWrite), preset: preset)
        try checkEncode(avformat_write_header(outFmt, nil), preset: preset)
    }

    /// Finds and opens the preset's encoder, configured for the output shape,
    /// parking the context on `ctx` before any throwing call (#295).
    private func makeEncoderContext(
        _ ctx: TranscodeContext,
        preset: TranscodePreset,
        sampleFmt: AVSampleFormat,
        globalHeader: Bool
    ) throws {
        guard let encoder = avcodec_find_encoder_by_name(preset.encoderName) else {
            throw AudioEngineError.encoderFailure(
                codec: preset.encoderName,
                underlying: TranscodeInternalError.noEncoder
            )
        }
        guard let encodeCtx = avcodec_alloc_context3(encoder) else {
            throw AudioEngineError.encoderFailure(codec: preset.encoderName, underlying: TranscodeInternalError.alloc)
        }
        ctx.encodeCtx = encodeCtx
        encodeCtx.pointee.sample_rate = ctx.outSampleRate
        encodeCtx.pointee.sample_fmt = sampleFmt
        encodeCtx.pointee.bit_rate = Int64(preset.targetKbps) * 1000
        encodeCtx.pointee.time_base = AVRational(num: 1, den: ctx.outSampleRate)
        av_channel_layout_default(&encodeCtx.pointee.ch_layout, ctx.outChannels)
        if globalHeader {
            encodeCtx.pointee.flags |= avCodecFlagGlobalHeader
        }
        try checkEncode(avcodec_open2(encodeCtx, encoder, nil), preset: preset)
    }

    /// The demux/decode/resample/encode/mux loop, cancellation-checked once
    /// per packet, then the three-stage drain: decoder, resampler, encoder.
    func runPipeline(_ ctx: TranscodeContext) throws {
        guard let inFmt = ctx.inFormatCtx, let pkt = ctx.packet else { return }
        while true {
            try Task.checkCancellation()
            let readRet = av_read_frame(inFmt, pkt)
            if readRet == avErrorEof { break }
            if readRet < 0 {
                // Mid-file damage the demuxer cannot resync past: keep the
                // audio decoded so far and finish (the ffmpeg CLI's default
                // tolerance) instead of failing the whole file.
                ctx.toleratedErrors += 1
                break
            }
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == ctx.streamIndex else { continue }
            try self.decodeAndBuffer(ctx, packet: pkt)
            try self.encodeBufferedFrames(ctx, includePartial: false)
        }
        // Drain the decoder, then the resampler's delay buffer, then encode
        // whatever remains (a final partial frame is allowed), then flush the
        // encoder and finalise the container.
        try self.decodeAndBuffer(ctx, packet: nil)
        try self.drainResampler(ctx)
        try self.encodeBufferedFrames(ctx, includePartial: true)
        guard ctx.nextPts > 0 else {
            // Not one decodable sample: this is a broken file, not damage
            // to tolerate. Never emit a silent header-only artifact.
            throw AudioEngineError.decoderFailure(codec: "FFmpeg", underlying: TranscodeInternalError.noAudio)
        }
        try self.pumpEncoder(ctx, frame: nil)
        try checkEncode(av_write_trailer(ctx.outFormatCtx), preset: nil)
    }

    // MARK: - Decode side

    /// Sends one packet (nil flushes) and buffers every decoded frame through
    /// the resampler into the FIFO.
    private func decodeAndBuffer(_ ctx: TranscodeContext, packet: UnsafeMutablePointer<AVPacket>?) throws {
        guard let decodeCtx = ctx.decodeCtx, let frame = ctx.decodedFrame else { return }
        let sendRet = avcodec_send_packet(decodeCtx, packet)
        if sendRet < 0, sendRet != averrorPosix(eagainCode), sendRet != avErrorEof {
            // A damaged packet: count it and skip it, the same tolerance as
            // FFmpegDecoder's playback loop (these files play fine). The
            // flush send (nil packet) still drains what the decoder holds.
            ctx.toleratedErrors += 1
            if packet != nil { return }
        }
        while true {
            let recvRet = avcodec_receive_frame(decodeCtx, frame)
            if recvRet == averrorPosix(eagainCode) || recvRet == avErrorEof { break }
            if recvRet < 0 {
                ctx.toleratedErrors += 1
                break
            }
            defer { av_frame_unref(frame) }
            try self.resampleIntoFIFO(ctx, samples: frame.pointee.nb_samples, input: frame)
        }
    }

    /// Runs `swr_convert` with a nil input until the delay buffer is empty.
    private func drainResampler(_ ctx: TranscodeContext) throws {
        while try self.resampleIntoFIFO(ctx, samples: 0, input: nil) > 0 {
            continue
        }
    }

    /// Converts one frame (or drains, when `input` is nil) into the FIFO.
    /// Returns the number of samples produced.
    @discardableResult
    private func resampleIntoFIFO(
        _ ctx: TranscodeContext,
        samples: Int32,
        input: UnsafeMutablePointer<AVFrame>?
    ) throws -> Int32 {
        guard let swr = ctx.swrCtx, let fifo = ctx.fifo, let encodeCtx = ctx.encodeCtx else { return 0 }
        let delay = swr_get_delay(swr, Int64(ctx.outSampleRate))
        let scaled = Int64(samples) * Int64(ctx.outSampleRate) / Int64(max(ctx.inSampleRate, 1))
        let outCount = Int32(delay + scaled) + 64
        guard outCount > 0 else { return 0 }

        var planes = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 8)
        return try planes.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            try checkEncode(
                av_samples_alloc(base, nil, ctx.outChannels, outCount, encodeCtx.pointee.sample_fmt, 0),
                preset: nil
            )
            defer { av_freep(base) }

            let inData = input.flatMap {
                unsafeBitCast($0.pointee.extended_data, to: UnsafePointer<UnsafePointer<UInt8>?>?.self)
            }
            let converted = swr_convert(swr, base, outCount, inData, samples)
            try checkEncode(converted, preset: nil)
            guard converted > 0 else { return 0 }

            try checkEncode(av_audio_fifo_realloc(fifo, av_audio_fifo_size(fifo) + converted), preset: nil)
            let written = UnsafeMutableRawPointer(base)
                .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            guard av_audio_fifo_write(fifo, written, converted) == converted else {
                throw AudioEngineError.encoderFailure(
                    codec: "FFmpeg/fifo",
                    underlying: TranscodeInternalError.alloc
                )
            }
            return converted
        }
    }

    // MARK: - Encode side

    /// Encodes full frames from the FIFO; with `includePartial`, also the
    /// final short frame at end of stream.
    private func encodeBufferedFrames(_ ctx: TranscodeContext, includePartial: Bool) throws {
        guard let encodeCtx = ctx.encodeCtx, let fifo = ctx.fifo else { return }
        let chunk = encodeCtx.pointee.frame_size > 0 ? encodeCtx.pointee.frame_size : 1152
        while av_audio_fifo_size(fifo) >= chunk {
            try self.encodeChunk(ctx, samples: chunk)
        }
        if includePartial {
            let remaining = av_audio_fifo_size(fifo)
            if remaining > 0 {
                try self.encodeChunk(ctx, samples: remaining)
            }
        }
    }

    /// Reads `samples` from the FIFO into a fresh frame, stamps its pts, and
    /// pumps it through the encoder.
    private func encodeChunk(_ ctx: TranscodeContext, samples: Int32) throws {
        guard let encodeCtx = ctx.encodeCtx, let fifo = ctx.fifo else { return }
        guard let frame = av_frame_alloc() else {
            throw AudioEngineError.encoderFailure(codec: "FFmpeg", underlying: TranscodeInternalError.alloc)
        }
        var frameForFree: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_frame_free(&frameForFree) }

        frame.pointee.nb_samples = samples
        frame.pointee.format = encodeCtx.pointee.sample_fmt.rawValue
        frame.pointee.sample_rate = encodeCtx.pointee.sample_rate
        try checkEncode(av_channel_layout_copy(&frame.pointee.ch_layout, &encodeCtx.pointee.ch_layout), preset: nil)
        try checkEncode(av_frame_get_buffer(frame, 0), preset: nil)

        let data = unsafeBitCast(
            frame.pointee.extended_data,
            to: UnsafeMutablePointer<UnsafeMutableRawPointer?>?.self
        )
        guard av_audio_fifo_read(fifo, data, samples) == samples else {
            throw AudioEngineError.encoderFailure(codec: "FFmpeg/fifo", underlying: TranscodeInternalError.alloc)
        }
        frame.pointee.pts = ctx.nextPts
        ctx.nextPts += Int64(samples)
        try self.pumpEncoder(ctx, frame: frame)
    }

    /// Sends a frame (nil flushes) and writes every packet the encoder
    /// produces, timestamps rescaled to the stream's time base.
    private func pumpEncoder(_ ctx: TranscodeContext, frame: UnsafeMutablePointer<AVFrame>?) throws {
        guard let encodeCtx = ctx.encodeCtx, let outFmt = ctx.outFormatCtx, let pkt = ctx.encodePacket else { return }
        let sendRet = avcodec_send_frame(encodeCtx, frame)
        if sendRet < 0, sendRet != averrorPosix(eagainCode), sendRet != avErrorEof {
            throw AudioEngineError.encoderFailure(codec: "FFmpeg", underlying: ffError(sendRet))
        }
        while true {
            let recvRet = avcodec_receive_packet(encodeCtx, pkt)
            if recvRet == averrorPosix(eagainCode) || recvRet == avErrorEof { break }
            try checkEncode(recvRet, preset: nil)
            pkt.pointee.stream_index = 0
            if let stream = outFmt.pointee.streams?[0] {
                av_packet_rescale_ts(pkt, encodeCtx.pointee.time_base, stream.pointee.time_base)
            }
            try checkEncode(av_interleaved_write_frame(outFmt, pkt), preset: nil)
        }
    }

    // MARK: - Probing (test support)

    /// Reads the container's metadata tags (format-level merged with the
    /// first stream's, since Ogg keeps tags on the stream), keys lowercased.
    static func readMetadata(at url: URL) throws -> [String: String] {
        var fmt: UnsafeMutablePointer<AVFormatContext>?
        defer { avformat_close_input(&fmt) }
        let openRet = avformat_open_input(&fmt, url.path, nil, nil)
        guard openRet >= 0, let fmtCtx = fmt else {
            throw AudioEngineError.accessDenied(url, underlying: ffError(openRet))
        }
        try checkDecode(avformat_find_stream_info(fmtCtx, nil))

        var result: [String: String] = [:]
        var dictionaries: [OpaquePointer?] = [fmtCtx.pointee.metadata]
        if fmtCtx.pointee.nb_streams > 0, let stream = fmtCtx.pointee.streams?[0] {
            dictionaries.append(stream.pointee.metadata)
        }
        for dictionary in dictionaries {
            var entry: UnsafeMutablePointer<AVDictionaryEntry>?
            while let next = av_dict_get(dictionary, "", entry, avDictIgnoreSuffix) {
                entry = next
                if let key = next.pointee.key, let value = next.pointee.value {
                    result[String(cString: key).lowercased()] = String(cString: value)
                }
            }
        }
        return result
    }
}

// MARK: - Error helpers

// File-private copies of FFmpegDecoder.swift's helpers (they are private to
// that file by design; the shape is kept identical).

private func ffError(_ code: Int32) -> Error {
    var buf = [CChar](repeating: 0, count: 256)
    av_strerror(code, &buf, buf.count)
    let message = buf.withUnsafeBufferPointer { ptr in
        ptr.baseAddress.flatMap {
            String(bytes: UnsafeRawBufferPointer(start: $0, count: strnlen($0, buf.count)), encoding: .utf8)
        } ?? "error \(code)"
    }
    return TranscodeInternalError.code(code, message)
}

/// Throws `decoderFailure` if `ret` is negative (the read side of the pipe).
private func checkDecode(_ ret: Int32) throws {
    guard ret >= 0 else {
        throw AudioEngineError.decoderFailure(codec: "FFmpeg", underlying: ffError(ret))
    }
}

/// Throws `encoderFailure` if `ret` is negative (the write side of the pipe).
private func checkEncode(_ ret: Int32, preset: TranscodePreset?) throws {
    guard ret >= 0 else {
        throw AudioEngineError.encoderFailure(codec: preset?.encoderName ?? "FFmpeg", underlying: ffError(ret))
    }
}

private enum TranscodeInternalError: Error, LocalizedError {
    case code(Int32, String)
    case noStream
    case noDecoder
    case noEncoder
    case noAudio
    case alloc

    var errorDescription: String? {
        switch self {
        case let .code(_, msg):
            msg

        case .noStream:
            "No audio stream found"

        case .noDecoder:
            "No decoder found for codec"

        case .noEncoder:
            "Encoder not available in this FFmpeg build"

        case .noAudio:
            "No decodable audio in the source"

        case .alloc:
            "Memory allocation failed"
        }
    }
}
