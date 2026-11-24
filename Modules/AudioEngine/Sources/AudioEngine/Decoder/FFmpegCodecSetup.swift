import CFFmpeg

// MARK: - FFmpegCodecSetup

/// What the app asks of an FFmpeg decoder before `avcodec_open2`.
///
/// The one place for it, called by both `FFmpegDecoder` (playback) and
/// `AudioTranscoder` (Phone Sync), so a request applies to both. Call it after
/// `avcodec_parameters_to_context`, which would overwrite some of these
/// fields, and before `avcodec_open2`, which reads them.
enum FFmpegCodecSetup {
    /// The decoders that can hand over the raw DSD bitstream
    /// (`AV_SAMPLE_FMT_DSD`) instead of converting it to PCM themselves.
    ///
    /// FFmpeg 9.1 deprecates the conversion inside the decoder
    /// (`FF_API_DSD_PCM`, removed at libavcodec 64), so these get the raw
    /// stream and the caller's own resampler converts it (#706). WavPack is
    /// here for its DSD files: it reads the request only on DSD frames, so a
    /// PCM WavPack file decodes as before.
    static let rawDSDCodecs: Set<AVCodecID> = [
        AV_CODEC_ID_DSD_LSBF,
        AV_CODEC_ID_DSD_MSBF,
        AV_CODEC_ID_DSD_LSBF_PLANAR,
        AV_CODEC_ID_DSD_MSBF_PLANAR,
        AV_CODEC_ID_DST,
        AV_CODEC_ID_WAVPACK,
    ]

    /// Configures `codecCtx` before it opens.
    static func prepare(_ codecCtx: UnsafeMutablePointer<AVCodecContext>) {
        if self.rawDSDCodecs.contains(codecCtx.pointee.codec_id) {
            codecCtx.pointee.request_sample_fmt = AV_SAMPLE_FMT_DSD
        }
    }
}
