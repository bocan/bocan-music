import CFFmpeg
import CryptoKit
import Foundation
import Observability

// MARK: - AudioTranscoder

/// Offline transcoder for sync-and-transcode (ADR-088): demux, decode,
/// resample, encode, mux, hash, all in-process through CFFmpeg.
///
/// The shape mirrors `FFmpegDecoder`: an actor on its own serial dispatch
/// queue (at `.utility`, since this is background preparation work, never the
/// realtime path), RAII ownership of every C allocation, and
/// `Task.checkCancellation()` once per packet-loop iteration. On any throw,
/// cancellation included, the destination file is removed: a partial artifact
/// must never survive to be hashed or served.
public actor AudioTranscoder {
    /// One process-wide queue: one encode at a time, per ADR-088's
    /// performance rule.
    private static let _executor = DispatchSerialQueue(
        label: "com.bocan.audio-transcoder",
        qos: .utility
    )

    /// Routes the actor onto the shared transcode queue.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self._executor.asUnownedSerialExecutor()
    }

    let log = AppLogger.make(.audio)

    public init() {}

    /// Transcodes `source` into `destination` at `preset`, writing `metadata`
    /// (title, artist, album, ...) into the artifact's tags. Returns the
    /// facts the sync ledger records. Throws `CancellationError` promptly on
    /// task cancellation; the destination is removed on every failure path.
    public func transcode(
        source: URL,
        to destination: URL,
        preset: TranscodePreset,
        metadata: [String: String] = [:]
    ) async throws -> TranscodeResult {
        let started = Date()
        self.log.debug("transcode.start", [
            "src": source.lastPathComponent,
            "preset": preset.rawValue,
        ])
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw AudioEngineError.fileNotFound(source)
        }

        let ctx = TranscodeContext()
        var finished = false
        defer {
            if !finished { self.removeArtifact(at: destination) }
        }

        try self.openInput(ctx, source: source)
        try self.openOutput(ctx, destination: destination, preset: preset, metadata: metadata)
        try self.runPipeline(ctx)
        if ctx.toleratedErrors > 0 {
            self.log.warning("transcode.damage.tolerated", [
                "src": source.lastPathComponent,
                "count": "\(ctx.toleratedErrors)",
            ])
        }

        let sha256 = try Self.sha256Hex(ofFileAt: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes[.size] as? Int64) ?? 0

        finished = true
        self.log.debug("transcode.end", [
            "src": source.lastPathComponent,
            "preset": preset.rawValue,
            "bytes": "\(size)",
            "ms": "\(Int(Date().timeIntervalSince(started) * 1000))",
        ])
        return TranscodeResult(sha256: sha256, size: size, bitrateKbps: preset.targetKbps)
    }

    // MARK: - Cleanup and hashing

    /// Deletes a partial artifact; never throws (the original error wins).
    private func removeArtifact(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            self.log.warning("transcode.cleanup.failed", [
                "path": url.lastPathComponent,
                "error": String(reflecting: error),
            ])
        }
    }

    /// Streams the file through SHA-256 in 1 MiB chunks and returns the
    /// lowercase-hex digest. (Same shape as Library's `ContentHashService`
    /// helper, which sits above this module in the DAG and is not importable.)
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            do {
                try handle.close()
            } catch {
                AppLogger.make(.audio).warning("transcode.hash.close.failed", [
                    "error": String(reflecting: error),
                ])
            }
        }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - TranscodeContext

/// RAII owner of every FFmpeg C allocation one transcode makes, following the
/// `FFContext` cleanup contract (#295): each resource is parked on a property
/// the instant it is allocated, and every free in `deinit` is NULL-safe, so a
/// throw partway through construction still tears down cleanly.
final class TranscodeContext {
    var inFormatCtx: UnsafeMutablePointer<AVFormatContext>?
    var decodeCtx: UnsafeMutablePointer<AVCodecContext>?
    var outFormatCtx: UnsafeMutablePointer<AVFormatContext>?
    var encodeCtx: UnsafeMutablePointer<AVCodecContext>?
    var swrCtx: OpaquePointer?
    var fifo: OpaquePointer?
    var packet: UnsafeMutablePointer<AVPacket>?
    var encodePacket: UnsafeMutablePointer<AVPacket>?
    var decodedFrame: UnsafeMutablePointer<AVFrame>?

    var streamIndex: Int32 = -1
    var inSampleRate: Int32 = 0
    var outSampleRate: Int32 = 0
    var outChannels: Int32 = 2
    var nextPts: Int64 = 0
    /// The input shape `swrCtx` was built for (with `inSampleRate`). A decoded
    /// frame that differs forces a rebuild before it is converted: the
    /// resampler reads one plane per configured input channel, so a mono
    /// frame handed to a stereo-configured context is a null-plane read.
    var swrInLayout = AVChannelLayout()
    var swrInFormat = AV_SAMPLE_FMT_NONE
    /// Damaged packets and demux errors skipped instead of fatal (the same
    /// tolerance as playback); the transcoder logs a warning when non-zero.
    var toleratedErrors = 0

    init() {
        self.packet = av_packet_alloc()
        self.encodePacket = av_packet_alloc()
        self.decodedFrame = av_frame_alloc()
    }

    deinit {
        // Order not significant: every free is NULL-safe.
        av_packet_free(&packet)
        av_packet_free(&encodePacket)
        av_frame_free(&decodedFrame)
        var swr = swrCtx
        swr_free(&swr)
        av_channel_layout_uninit(&swrInLayout)
        if let fifo { av_audio_fifo_free(fifo) }
        var dec = decodeCtx
        avcodec_free_context(&dec)
        var enc = encodeCtx
        avcodec_free_context(&enc)
        var inFmt = inFormatCtx
        avformat_close_input(&inFmt)
        if let outFmt = outFormatCtx {
            if outFmt.pointee.pb != nil {
                avio_closep(&outFmt.pointee.pb)
            }
            avformat_free_context(outFmt)
        }
    }
}
