import CFFmpeg
import Foundation
import Testing
@testable import AudioEngine

// MARK: - What the linked FFmpeg must provide (ADR-096)

/// The contract between the app and the FFmpeg it links.
///
/// The FFmpeg is the project's own LGPL source build
/// (`Scripts/build-ffmpeg-lgpl.sh`). A change to its configure line can drop
/// a decoder without any other test noticing, because the codec fixtures do
/// not cover every format. These tests ask the linked library itself, with no
/// fixture files, so the list here is what a configure change has to answer
/// to. They also assert the licence: a build that picked up Homebrew's GPL
/// FFmpeg through a stray search path fails here, not in a release.
@Suite("Required FFmpeg codecs")
struct RequiredCodecsTests {
    // MARK: - Licence

    @Test("every FFmpeg library is the LGPL v2.1-or-later build")
    func licence() {
        let licences = [
            "libavutil": String(cString: avutil_license()),
            "libavcodec": String(cString: avcodec_license()),
            "libavformat": String(cString: avformat_license()),
            "libswresample": String(cString: swresample_license()),
        ]
        for (library, licence) in licences {
            #expect(licence == "LGPL version 2.1 or later", "\(library) reports: \(licence)")
        }
    }

    @Test("the configure line asks for neither the GPL, version 3 nor nonfree code")
    func configureLine() {
        let configuration = String(cString: avcodec_configuration())
        for flag in ["--enable-gpl", "--enable-version3", "--enable-nonfree"] {
            #expect(!configuration.contains(flag), "configured with \(flag)")
        }
    }

    // MARK: - Decoders

    /// Every codec a non-AVFoundation format in `FormatSniffer` can carry, and
    /// the AVFoundation ones FFmpeg decodes as a fallback or from a stream.
    @Test(
        "a decoder exists for the codec",
        arguments: [
            "vorbis", "speex", "opus", "flac", // Ogg and raw Opus
            "mp1", "mp2", "mp3",
            "aac", "alac",
            "ape", "wavpack", "tta", "musepack7", "musepack8",
            "dsd_lsbf", "dsd_msbf", "dsd_lsbf_planar", "dsd_msbf_planar", // DSF and DSDIFF
            "ac3", "eac3", "dts", "truehd", "mlp",
            "wmav1", "wmav2", "wmapro", "wmalossless",
            // PCM, for AU, Wave64, RF64, WAV and AIFF.
            "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_s32le", "pcm_s32be",
            "pcm_f32le", "pcm_f32be", "pcm_f64le", "pcm_u8", "pcm_s8", "pcm_mulaw", "pcm_alaw",
        ]
    )
    func decoder(codec: String) throws {
        let descriptor = try #require(avcodec_descriptor_get_by_name(codec), "FFmpeg does not know the codec \(codec)")
        #expect(avcodec_find_decoder(descriptor.pointee.id) != nil, "no decoder for \(codec)")
    }

    // MARK: - Demuxers

    @Test(
        "a demuxer exists for the container",
        arguments: [
            "ogg", "matroska", "asf", "ape", "wv", "tta", "mpc", "mpc8",
            "dsf", "iff", // iff reads DSDIFF
            "au", "w64", "wav", "aiff", // wav reads RF64
            "mov", "mp3", "aac", "flac",
            "ac3", "eac3", "dts", "truehd", "mlp",
            "hls", // HLS internet radio
        ]
    )
    func demuxer(container: String) {
        #expect(av_find_input_format(container) != nil, "no demuxer for \(container)")
    }

    // MARK: - Protocols

    @Test("the protocols that local and remote playback use are present")
    func protocols() throws {
        var available: Set<String> = []
        var opaque: UnsafeMutableRawPointer?
        while let name = avio_enum_protocols(&opaque, 0) {
            available.insert(String(cString: name))
        }
        // The remote protocols the decoder allows, plus `file` for local input.
        let allowed = try #require(FFmpegDecoder.allowedRemoteProtocols(isRemote: true))
        let needed = Set(allowed.split(separator: ",").map(String.init)).union(["file"])
        #expect(needed.isSubset(of: available), "missing: \(needed.subtracting(available).sorted())")
    }

    // MARK: - Phone Sync transcoding (ADR-088)

    @Test("every transcode preset has its encoder and its container", arguments: TranscodePreset.allCases)
    func transcode(preset: TranscodePreset) {
        #expect(
            avcodec_find_encoder_by_name(preset.encoderName) != nil,
            "no encoder named \(preset.encoderName)"
        )
        // The transcoder lets FFmpeg choose the container from the file name.
        #expect(
            av_guess_format(nil, "track.\(preset.fileExtension)", nil) != nil,
            "no muxer for .\(preset.fileExtension)"
        )
    }
}
