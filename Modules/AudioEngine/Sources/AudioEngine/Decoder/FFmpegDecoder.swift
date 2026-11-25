// @preconcurrency: AVAudioPCMBuffer/AVAudioFormat lack Sendable; safe because
// FFmpegDecoder is the sole owner of its buffers.
// Remove once AVFoundation adopts Sendable annotations (FB13119463).
@preconcurrency import AVFoundation
import CFFmpeg
import Foundation
import Observability

// MARK: - FFmpeg sentinels

/// `AV_NOPTS_VALUE` — sentinel for "no presentation timestamp".
private let avNoPtsValue = Int64(bitPattern: 0x8000_0000_0000_0000)

/// Negates a POSIX error code, equivalent to the C macro `AVERROR(e)`.
private func averrorPosix(_ code: Int32) -> Int32 {
    -code
}

/// `AVERROR_EOF` — end of stream (not importable; uses C casts internally).
private let avErrorEof: Int32 = -541_478_725

/// macOS `EAGAIN` — resource temporarily unavailable.
private let eagainCode: Int32 = 35

// MARK: - FFmpegDecoder

public actor FFmpegDecoder: Decoder {
    private static let _executor = DispatchSerialQueue(
        label: "com.bocan.ffmpeg-decoder",
        qos: .userInitiated
    )
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self._executor.asUnownedSerialExecutor()
    }

    /// RAII owner of every FFmpeg C allocation the decoder makes.
    ///
    /// Cleanup contract (#295): each resource is parked on a property the
    /// instant it's allocated, and every free in `deinit` is NULL-safe, so a
    /// throw partway through construction still tears down cleanly. That's
    /// why `openAndConfigure` assigns `ctx.codecCtx` *before* the throwing
    /// `avcodec_open2` call. The one allocation not owned here until fully
    /// built is the SWR resampler -- `buildSWR` frees it on its own throw
    /// paths and only hands back a live pointer to park on `swrCtx`.
    /// Internal, not private, so the seek in `FFmpegDecoder+Seek.swift` can
    /// reach it.
    final class FFContext {
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
            // Order not significant: every free is NULL-safe, so this covers partial-alloc state.
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

    // MARK: - Properties

    let ctx: FFContext
    /// Internal so the StreamDetails extension can watch this stream's
    /// metadata events (#386); `FFContext` itself stays private.
    var audioStreamIndex: Int32 {
        self.ctx.streamIndex
    }

    let log = AppLogger.make(.audio)
    private let url: URL

    public nonisolated let sourceFormat: AVAudioFormat
    public nonisolated let duration: TimeInterval

    /// Measured source facts captured at open time (ADR-078 slice 5): container,
    /// codec and profile, sample rate, channels, claimed bitrate, and, for
    /// network streams, the ICY headers.
    public nonisolated let streamDetails: StreamDetails

    /// The short codec name FFmpeg opened the stream with (ADR-092). The
    /// vocabulary the AVFoundation route is mapped onto, so a file that both
    /// can decode reports one name.
    public nonisolated var codec: String? {
        self.streamDetails.codec
    }

    /// ICY now-playing titles (ADR-078 slice 5), de-interleaved by FFmpeg's http
    /// protocol and surfaced from the packet-read loop. Local files never
    /// emit. Finishes when the decoder closes. The backing members are
    /// internal (not private) so FFmpegDecoder+StreamDetails.swift can emit.
    public nonisolated let titleUpdates: AsyncStream<String>
    nonisolated let titleContinuation: AsyncStream<String>.Continuation
    var lastEmittedTitle: String?

    // Internal so `FFmpegDecoder+Seek.swift` can reset them.
    var positionSeconds: TimeInterval = 0
    var residualBuffer: [Float] = []

    /// The sample a seek asked for, until the first sample at or after it has
    /// been decoded; output before it is dropped (#705). The frame after one
    /// with no timestamp starts at `nextFrameSample`.
    var seekTargetSample: Int64?
    var nextFrameSample: Int64?

    /// Channels the resampler emits and `sourceFormat` carries. The file's own
    /// count when it has more than two named channels the engine can
    /// describe (#522); otherwise two, with swresample folding to stereo as
    /// it always did for mono, stereo and layouts it cannot name.
    let outChannels: Int32

    /// True for a remote source with no known duration (internet radio, vs.
    /// a finite Subsonic/podcast HTTP track or local file). EOF here only
    /// happens once FFmpeg's reconnect budget is exhausted, so it must
    /// surface as a failure rather than a silent end-of-track.
    let isUnboundedRemoteStream: Bool // internal: title emission gates on it (#386)

    public var position: TimeInterval {
        self.positionSeconds
    }

    // MARK: - Init

    public init(url: URL) throws {
        // HTTP(S) URLs (internet radio) skip the file-exists check:
        // `avformat_open_input` handles network protocols directly. Local
        // and bare-path URLs still fail fast on a missing file.
        let isHTTP = (url.scheme?.lowercased()).map { $0 == "http" || $0 == "https" } ?? false
        if !isHTTP, !FileManager.default.fileExists(atPath: url.path) {
            throw AudioEngineError.fileNotFound(url)
        }
        let ctx = FFContext()
        self.ctx = ctx
        self.url = url
        let setup = try Self.openAndConfigure(ctx: ctx, url: url)
        self.streamDetails = setup.details
        var continuation: AsyncStream<String>.Continuation!
        self.titleUpdates = AsyncStream { continuation = $0 }
        self.titleContinuation = continuation
        self.duration = Self.detectDuration(ctx: ctx)
        self.isUnboundedRemoteStream = isHTTP && self.duration <= 0
        // A multichannel source keeps its own layout so the engine folds it
        // through the same converter as the AVFoundation route (#522). Below
        // three channels, or when the layout cannot be described, the
        // resampler has already folded to stereo.
        let layout = setup.nativeLayout ?? StereoLayout.layout
        self.outChannels = Int32(layout.channelCount)
        self.sourceFormat = AVAudioFormat(
            standardFormatWithSampleRate: setup.sampleRate,
            channelLayout: layout
        )
    }

    // MARK: - Decoder

    public func read(into buffer: AVAudioPCMBuffer) async throws -> AVAudioFrameCount {
        try Task.checkCancellation()
        let capacity = Int(buffer.frameCapacity)
        var totalFrames = 0

        totalFrames += drainResidual(into: buffer, startFrame: 0, capacity: capacity)

        while totalFrames < capacity {
            try Task.checkCancellation()
            let raw = try readNextFrames()
            guard !raw.isEmpty else { break }
            let overflow = copyInterleaved(raw, into: buffer, startFrame: totalFrames, capacity: capacity)
            totalFrames += (raw.count - overflow.count) / Int(self.outChannels)
            if !overflow.isEmpty {
                self.residualBuffer = overflow
                break
            }
        }

        buffer.frameLength = AVAudioFrameCount(totalFrames)
        if self.sourceFormat.sampleRate > 0 {
            self.positionSeconds += TimeInterval(totalFrames) / self.sourceFormat.sampleRate
        }
        return buffer.frameLength
    }

    // `seek(to:)` is in FFmpegDecoder+Seek.swift.

    public func close() async {
        self.titleContinuation.finish()
        self.log.debug("ffmpeg.decoder.closed", ["url": self.url.lastPathComponent])
    }
}

private extension FFmpegDecoder {
    /// Opens the format context, finds the best audio stream, opens the codec,
    /// and initialises the SWR resampler (`FFmpegDecoder+Setup.swift`).
    private static func openAndConfigure(ctx: FFContext, url: URL) throws -> FFmpegSourceSetup {
        // For HTTP / HTTPS URLs pass the full absolute string so FFmpeg's
        // network protocol handlers fire. Everything else (file URLs,
        // bare paths) uses the on-disk path so security-scoped bookmark
        // URLs aren't double-encoded.
        let isHTTP = (url.scheme?.lowercased()).map { $0 == "http" || $0 == "https" } ?? false
        let inputPath = isHTTP ? url.absoluteString : url.path

        // Remote inputs are whitelisted to network protocols only, so a
        // malicious server can't redirect the demuxer to a local `file:` /
        // `concat:` / `subfile:` URL (#280). Local files get no whitelist.
        var opts: OpaquePointer? // AVDictionary*
        defer { av_dict_free(&opts) }
        for (key, value) in self.openOptions(isHTTP: isHTTP) {
            av_dict_set(&opts, key, value, 0)
        }

        // Either way ctx.formatCtx ends up NULL-or-owned, so FFContext.deinit
        // covers both the failure and partial-success throw paths. (#295)
        let openRet = avformat_open_input(&ctx.formatCtx, inputPath, nil, &opts)
        if openRet < 0 {
            throw AudioEngineError.accessDenied(url, underlying: ffError(openRet))
        }
        try self.ffCheck(avformat_find_stream_info(ctx.formatCtx, nil))

        let streamIdx = av_find_best_stream(ctx.formatCtx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard streamIdx >= 0 else {
            throw AudioEngineError.decoderFailure(codec: "FFmpeg", underlying: FFmpegInternalError.noStream)
        }
        ctx.streamIndex = streamIdx

        guard let stream = ctx.formatCtx?.pointee.streams?[Int(streamIdx)],
              let codecParams = stream.pointee.codecpar else {
            throw AudioEngineError.decoderFailure(codec: "FFmpeg", underlying: FFmpegInternalError.noStream)
        }

        guard let codec = avcodec_find_decoder(codecParams.pointee.codec_id) else {
            throw AudioEngineError.decoderFailure(codec: "FFmpeg", underlying: FFmpegInternalError.noDecoder)
        }

        guard let codecCtx = avcodec_alloc_context3(codec) else {
            throw AudioEngineError.decoderFailure(codec: "FFmpeg", underlying: FFmpegInternalError.alloc)
        }
        // Parked before the throwing calls below so a failure there is still
        // covered by FFContext.deinit's avcodec_free_context. (#295)
        ctx.codecCtx = codecCtx

        try self.ffCheck(avcodec_parameters_to_context(codecCtx, codecParams))
        // Lets the decoder move a frame's timestamp when it trims samples
        // (encoder delay, pre-roll), which the seek trim reads (#705).
        codecCtx.pointee.pkt_timebase = stream.pointee.time_base
        FFmpegCodecSetup.prepare(codecCtx)
        try self.ffCheck(avcodec_open2(codecCtx, codec, nil))
        // More than two named channels keep their layout, so the engine's one
        // converter folds them exactly as it folds an AVFoundation-decoded
        // file (#522). Anything else folds to stereo in swresample as before.
        let nativeLayout = Self.nativeLayout(for: codecCtx)
        // buildSWR owns its allocation until it returns successfully; only a
        // live, fully-initialised resampler reaches ctx.swrCtx. (#295)
        ctx.swrCtx = try self.buildSWR(codecCtx: codecCtx, keepSourceChannels: nativeLayout != nil)

        let details = Self.captureDetails(formatCtx: ctx.formatCtx, codecParams: codecParams, isHTTP: isHTTP)
        return FFmpegSourceSetup(
            sampleRate: Double(codecCtx.pointee.sample_rate),
            details: details,
            nativeLayout: nativeLayout
        )
    }

    /// Determines stream duration from stream metadata or the container header.
    private static func detectDuration(ctx: FFContext) -> TimeInterval {
        guard let stream = ctx.formatCtx?.pointee.streams?[Int(ctx.streamIndex)] else { return 0 }
        let tbNum = stream.pointee.time_base.num
        let tbDen = stream.pointee.time_base.den
        let rawDur = stream.pointee.duration
        if rawDur != avNoPtsValue, tbDen > 0 {
            return TimeInterval(rawDur) * TimeInterval(tbNum) / TimeInterval(tbDen)
        }
        if let fmtCtx = ctx.formatCtx, fmtCtx.pointee.duration != avNoPtsValue {
            return TimeInterval(fmtCtx.pointee.duration) / TimeInterval(AV_TIME_BASE)
        }
        return 0
    }
}

// MARK: - Error bridging

extension FFmpegDecoder {
    /// Throws `decoderFailure` if `ret` is negative. Internal so the resampler
    /// setup in `FFmpegDecoder+Setup.swift` can report through the same path.
    static func ffCheck(_ ret: Int32, codec: String = "FFmpeg") throws {
        guard ret >= 0 else {
            throw AudioEngineError.decoderFailure(codec: codec, underlying: ffError(ret))
        }
    }
}

// MARK: - Decode helpers

/// Internal, not private: the seek trim in FFmpegDecoder+Seek.swift calls
/// `convertFrame`.
extension FFmpegDecoder {
    func readNextFrames() throws -> [Float] {
        guard let fmtCtx = ctx.formatCtx,
              let codecCtx = ctx.codecCtx,
              let swrCtx = ctx.swrCtx,
              let pkt = ctx.packet,
              let frm = ctx.frame else { return [] }

        var result: [Float] = []

        outer: while true {
            let readRet = av_read_frame(fmtCtx, pkt)
            if readRet == avErrorEof {
                try self.finishAtEOF(codecCtx, swrCtx: swrCtx, frame: frm, readRet: readRet, into: &result)
                break
            }
            if readRet < 0 {
                throw AudioEngineError.decoderFailure(codec: "FFmpeg", underlying: ffError(readRet))
            }
            // ICY now-playing (ADR-078 slice 5): checked before the stream-index
            // guard because the update can ride along with any packet.
            self.consumeMetadataUpdate(fmtCtx: fmtCtx)
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == self.ctx.streamIndex else { continue }
            let sendRet = avcodec_send_packet(codecCtx, pkt)
            if sendRet < 0, sendRet != averrorPosix(eagainCode) {
                continue
            }
            switch try self.receiveConverted(codecCtx, swrCtx: swrCtx, frame: frm) {
            case let .samples(converted):
                return converted

            case .needPacket:
                continue outer

            case .ended:
                break outer
            }
        }
        return result
    }

    /// Receives frames until one has samples to keep. A frame wholly before
    /// a seek target converts to nothing and is skipped (#705); a decode
    /// error drops that frame and asks for the next packet, as before.
    func receiveConverted(
        _ codecCtx: UnsafeMutablePointer<AVCodecContext>,
        swrCtx: OpaquePointer,
        frame: UnsafeMutablePointer<AVFrame>
    ) throws -> ReceiveOutcome {
        while true {
            let recvRet = avcodec_receive_frame(codecCtx, frame)
            if recvRet == avErrorEof {
                return .ended
            }
            if recvRet < 0 {
                return .needPacket
            }
            let converted = try self.convertTrimmingToSeekTarget(frame, swrCtx: swrCtx)
            av_frame_unref(frame)
            if !converted.isEmpty {
                return .samples(converted)
            }
        }
    }

    /// Drains buffered frames at a finite source's real end; throws instead
    /// for a live stream, where EOF means FFmpeg gave up reconnecting.
    func finishAtEOF(
        _ codecCtx: UnsafeMutablePointer<AVCodecContext>,
        swrCtx: OpaquePointer,
        frame: UnsafeMutablePointer<AVFrame>,
        readRet: Int32,
        into result: inout [Float]
    ) throws {
        if self.isUnboundedRemoteStream {
            throw AudioEngineError.decoderFailure(codec: "FFmpeg", underlying: ffError(readRet))
        }
        _ = avcodec_send_packet(codecCtx, nil)
        try self.drainCodec(codecCtx, swrCtx: swrCtx, frame: frame, into: &result)
    }

    func drainCodec(
        _ codecCtx: UnsafeMutablePointer<AVCodecContext>,
        swrCtx: OpaquePointer,
        frame: UnsafeMutablePointer<AVFrame>,
        into result: inout [Float]
    ) throws {
        while true {
            let ret = avcodec_receive_frame(codecCtx, frame)
            if ret == avErrorEof || ret == averrorPosix(eagainCode) {
                break
            }
            if ret < 0 {
                break
            }
            let converted = try self.convertTrimmingToSeekTarget(frame, swrCtx: swrCtx)
            av_frame_unref(frame)
            result.append(contentsOf: converted)
        }
    }

    func convertFrame(
        _ frame: UnsafeMutablePointer<AVFrame>,
        swrCtx: OpaquePointer
    ) throws -> [Float] {
        let nbSamples = Int(frame.pointee.nb_samples)
        guard nbSamples > 0 else { return [] }
        let channels = Int(self.outChannels)
        let outCount = nbSamples + 256
        let byteCount = outCount * MemoryLayout<Float>.size
        // One planar output buffer per channel the resampler emits (#522).
        let planes = (0 ..< channels).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        }
        defer {
            for plane in planes {
                plane.deallocate()
            }
        }
        var outPtrs: [UnsafeMutablePointer<UInt8>?] = planes.map { $0.assumingMemoryBound(to: UInt8.self) }
        let totalFrames: Int32 = outPtrs.withUnsafeMutableBufferPointer { ptr in
            let inData = unsafeBitCast(
                frame.pointee.extended_data,
                to: UnsafePointer<UnsafePointer<UInt8>?>?.self
            )
            return swr_convert(swrCtx, ptr.baseAddress, Int32(outCount), inData, Int32(nbSamples))
        }
        if totalFrames < 0 {
            throw AudioEngineError.decoderFailure(codec: "FFmpeg/swr", underlying: ffError(totalFrames))
        }
        let n = Int(totalFrames)
        let floats = planes.map { $0.assumingMemoryBound(to: Float.self) }
        var result = [Float](repeating: 0, count: n * channels)
        for i in 0 ..< n {
            for c in 0 ..< channels {
                result[i * channels + c] = floats[c][i]
            }
        }
        return result
    }

    func copyInterleaved(
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

    func drainResidual(
        into buffer: AVAudioPCMBuffer,
        startFrame: Int,
        capacity: Int
    ) -> Int {
        guard !self.residualBuffer.isEmpty else { return 0 }
        let overflow = self.copyInterleaved(
            self.residualBuffer,
            into: buffer,
            startFrame: startFrame,
            capacity: capacity
        )
        let written = (residualBuffer.count - overflow.count) / Int(self.outChannels)
        self.residualBuffer = overflow
        return written
    }
}

// MARK: - Error helpers

private func ffError(_ code: Int32) -> Error {
    var buf = [CChar](repeating: 0, count: 256)
    av_strerror(code, &buf, buf.count)
    let message = buf.withUnsafeBufferPointer { ptr in
        ptr.baseAddress.flatMap {
            String(bytes: UnsafeRawBufferPointer(start: $0, count: strnlen($0, buf.count)), encoding: .utf8)
        } ?? "error \(code)"
    }
    return FFmpegInternalError.code(code, message)
}
