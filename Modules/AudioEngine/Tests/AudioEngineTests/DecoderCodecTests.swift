@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - Decoder codec vocabulary (ADR-092 slice 1)

/// Both decoder routes name the codec with FFmpeg's short name, so the
/// now-playing badge reads the same for a file whichever decoder opens it.
/// The AVFoundation names come from the file's format ID, the FFmpeg ones
/// from the open-time `StreamDetails`.
@Suite("Decoder codec names")
struct DecoderCodecTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "Missing fixture: \(name)")
    }

    // MARK: - AVFoundation route

    /// The container says nothing: `.m4a` carries AAC, ALAC and E-AC-3 alike,
    /// and each must name its own codec (#529).
    @Test(
        "AVFoundationDecoder names the codec, not the container",
        arguments: [
            ("sine-1s-44100-16-stereo.wav", "pcm"),
            ("sine-1s-44100-16-stereo.aiff", "pcm"),
            ("sine-1s-44100-24-stereo.flac", "flac"),
            ("sample.mp3", "mp3"),
            ("sample-aac.m4a", "aac"),
            ("sample-alac.m4a", "alac"),
            ("surround-lsrs-eac3-48000.m4a", "eac3"),
            ("surround-lsrs-48000.eac3", "eac3"),
        ]
    )
    func avFoundationCodec(fixture: String, expected: String) async throws {
        let decoder = try AVFoundationDecoder(url: fixtureURL(fixture))
        #expect(decoder.codec == expected)
        await decoder.close()
    }

    // MARK: - FFmpeg route

    @Test(
        "FFmpegDecoder reports the short codec name it opened the stream with",
        arguments: [
            ("sine-1s-48000-stereo.ogg", "vorbis"),
            ("sine-1s-48000-stereo.opus", "opus"),
            ("sine-1s-44100-stereo.wv", "wavpack"),
            ("surround-lsrs-48000.eac3", "eac3"),
            ("surround-lsrs-48000.thd", "truehd"),
            ("sine-250ms-dsd64-stereo.dsf", "dsd_lsbf_planar"),
        ]
    )
    func ffmpegCodec(fixture: String, expected: String) async throws {
        let decoder = try FFmpegDecoder(url: fixtureURL(fixture))
        #expect(decoder.codec == expected)
        await decoder.close()
    }

    // MARK: - One vocabulary

    /// The whole point of the mapping: a file that both decoders can open
    /// reports one name, so the badge does not change when the routing does.
    @Test("both routes agree on a raw E-AC-3 file")
    func routesAgree() async throws {
        let url = try fixtureURL("surround-lsrs-48000.eac3")
        let avf = try AVFoundationDecoder(url: url)
        let ffmpeg = try FFmpegDecoder(url: url)
        #expect(avf.codec == ffmpeg.codec)
        await avf.close()
        await ffmpeg.close()
    }

    // MARK: - Format-ID mapping

    @Test(
        "the format-ID mapping speaks FFmpeg's vocabulary",
        arguments: [
            ("lpcm", "pcm"),
            (".mp3", "mp3"),
            (".mp2", "mp2"),
            ("aac ", "aac"),
            ("aach", "aac"),
            ("alac", "alac"),
            ("flac", "flac"),
            ("opus", "opus"),
            ("vorb", "vorbis"),
            ("ec-3", "eac3"),
            ("ac-3", "ac3"),
            // Unmapped: the four-character code trimmed and lowercased, which
            // is the best guess available and never a container name.
            ("QDM2", "qdm2"),
            ("ima4", "ima4"),
        ]
    )
    func formatIDMapping(code: String, expected: String) {
        #expect(AVFoundationDecoder.codecName(forFourCC: code) == expected)
    }

    @Test("an empty format ID names no codec")
    func emptyFormatID() {
        #expect(AVFoundationDecoder.codecName(forFourCC: "    ") == nil)
        #expect(AVFoundationDecoder.codecName(forFourCC: "") == nil)
    }
}
