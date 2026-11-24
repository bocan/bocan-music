import CFFmpeg
import Foundation
import Testing
@testable import AudioEngine

// MARK: - FFmpegCodecSetupTests

/// What the app asks of an FFmpeg decoder before it opens (#706).
@Suite("FFmpeg codec setup")
struct FFmpegCodecSetupTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "Missing fixture: \(name)")
    }

    private func sourceText(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AudioEngineTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/AudioEngine/
            .appendingPathComponent("Sources/AudioEngine/\(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The request field after `prepare` for a fresh context of `codecName`.
    private func requestedFormat(for codecName: String) throws -> AVSampleFormat {
        let descriptor = try #require(avcodec_descriptor_get_by_name(codecName))
        let codec = try #require(avcodec_find_decoder(descriptor.pointee.id))
        var context = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        let codecCtx = try #require(context)
        FFmpegCodecSetup.prepare(codecCtx)
        return codecCtx.pointee.request_sample_fmt
    }

    @Test(
        "DSD, DST and WavPack decoders are asked for the raw DSD stream",
        arguments: ["dsd_lsbf", "dsd_msbf", "dsd_lsbf_planar", "dsd_msbf_planar", "dst", "wavpack"]
    )
    func rawDSDRequested(codec: String) throws {
        #expect(try self.requestedFormat(for: codec) == AV_SAMPLE_FMT_DSD)
    }

    @Test("Other decoders keep FFmpeg's default format", arguments: ["flac", "opus", "vorbis", "mp3", "aac", "ape"])
    func othersUntouched(codec: String) throws {
        #expect(try self.requestedFormat(for: codec) == AV_SAMPLE_FMT_NONE)
    }

    /// Guards the linked FFmpeg, not only our request: if a release stopped
    /// honouring it, DSD would silently fall back to the deprecated path.
    @Test("The linked FFmpeg hands a prepared DSF stream over as raw DSD")
    func linkedFFmpegHonoursTheRequest() throws {
        let path = try self.fixtureURL("sine-250ms-dsd64-stereo.dsf").path
        var format: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_open_input(&format, path, nil, nil) >= 0)
        defer { avformat_close_input(&format) }
        try #require(avformat_find_stream_info(format, nil) >= 0)
        let index = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        let stream = try #require(format?.pointee.streams?[Int(index)])
        let codec = try #require(avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id))
        var context = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        let codecCtx = try #require(context)
        try #require(avcodec_parameters_to_context(codecCtx, stream.pointee.codecpar) >= 0)
        FFmpegCodecSetup.prepare(codecCtx)
        try #require(avcodec_open2(codecCtx, codec, nil) >= 0)
        #expect(codecCtx.pointee.sample_fmt == AV_SAMPLE_FMT_DSD)
    }

    @Test("Playback and Phone Sync both prepare the codec before opening it", arguments: [
        "Decoder/FFmpegDecoder.swift",
        "Transcode/AudioTranscoder+Pipeline.swift",
    ])
    func bothOpenSitesPrepare(file: String) throws {
        let source = try self.sourceText(file)
        let prepare = try #require(source.range(of: "FFmpegCodecSetup.prepare("), "\(file) never prepares the codec")
        let open = try #require(source.range(of: "avcodec_open2(", range: prepare.upperBound ..< source.endIndex))
        let fill = try #require(source.range(of: "avcodec_parameters_to_context("))
        // After the parameters copy, which would overwrite the request, and before the open.
        #expect(fill.lowerBound < prepare.lowerBound && prepare.lowerBound < open.lowerBound)
    }
}
