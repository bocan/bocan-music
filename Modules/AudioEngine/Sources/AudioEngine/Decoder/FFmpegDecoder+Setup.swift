@preconcurrency import AVFoundation
import CFFmpeg
import Foundation

// MARK: - FFmpegSourceSetup

/// What opening the codec teaches the decoder before its first read.
struct FFmpegSourceSetup {
    /// The stream's native sample rate.
    let sampleRate: Double
    /// Measured source facts captured while the codec parameters are in
    /// hand (ADR-078 slice 5).
    let details: StreamDetails
    /// The layout the resampler emits when it keeps the source's channels
    /// (#522); nil when it folds to stereo.
    let nativeLayout: AVAudioChannelLayout?
}

// MARK: - FFmpegDecoder + resampler setup

extension FFmpegDecoder {
    /// The codec's own channel layout as CoreAudio descriptions, when it has
    /// more than two channels and every one has a name the engine knows
    /// (#522). Nil means the resampler folds to stereo as it always did.
    static func nativeLayout(for codecCtx: UnsafeMutablePointer<AVCodecContext>) -> AVAudioChannelLayout? {
        guard codecCtx.pointee.ch_layout.nb_channels > 2 else { return nil }
        return withUnsafePointer(to: &codecCtx.pointee.ch_layout) { layout in
            ChannelLayoutBridge.labels(for: layout).map(ChannelLayoutBridge.layout(labels:))
        }
    }

    /// Allocates and configures an SWR resampler for the given codec context.
    /// With `keepSourceChannels` the output layout is the codec's own, so the
    /// resampler only changes the sample format; otherwise it folds to stereo.
    static func buildSWR(
        codecCtx: UnsafeMutablePointer<AVCodecContext>,
        keepSourceChannels: Bool = false
    ) throws -> OpaquePointer {
        let sampleRate = Int32(codecCtx.pointee.sample_rate)
        var outLayout = AVChannelLayout()
        if keepSourceChannels {
            try self.ffCheck(av_channel_layout_copy(&outLayout, &codecCtx.pointee.ch_layout), codec: "FFmpeg/swr")
        } else {
            av_channel_layout_default(&outLayout, 2)
        }
        defer { av_channel_layout_uninit(&outLayout) }

        // swr_alloc_set_opts2 can allocate and still error, so free on every
        // throw path (#295) unless ownership is handed back to the caller.
        var swrCtx: OpaquePointer?
        var handedOff = false
        defer {
            if !handedOff {
                swr_free(&swrCtx)
            }
        }

        let ret = swr_alloc_set_opts2(
            &swrCtx,
            &outLayout,
            AV_SAMPLE_FMT_FLTP,
            sampleRate,
            &codecCtx.pointee.ch_layout,
            codecCtx.pointee.sample_fmt,
            sampleRate,
            0,
            nil
        )
        try self.ffCheck(ret, codec: "FFmpeg/swr")
        try self.ffCheck(swr_init(swrCtx), codec: "FFmpeg/swr")

        guard let swr = swrCtx else {
            throw AudioEngineError.decoderFailure(codec: "FFmpeg/swr", underlying: FFmpegInternalError.alloc)
        }
        handedOff = true
        return swr
    }
}
