import Foundation
import Testing
@testable import AudioEngine

// MARK: - StreamDetails tests (phase 27-5)

@Suite("StreamDetails")
struct StreamDetailsTests {
    // MARK: - ICY header parsing

    @Test("parses a realistic icy header block, lowercasing keys")
    func parsesIcyHeaders() {
        let raw = """
        icy-br: 128\r
        icy-pub: 1\r
        ICY-Name: SomaFM: Groove Salad\r
        icy-genre: Ambient Chill\r
        icy-url: https://somafm.com/groovesalad/\r
        icy-metaint: 16000\r
        icy-notice1: <BR>This stream requires <a href="http://www.winamp.com">Winamp</a><BR>
        """
        let headers = StreamDetails.parseIcyHeaders(raw)

        #expect(headers["icy-name"] == "SomaFM: Groove Salad")
        #expect(headers["icy-genre"] == "Ambient Chill")
        #expect(headers["icy-url"] == "https://somafm.com/groovesalad/")
        #expect(headers["icy-br"] == "128")
        #expect(headers["icy-metaint"] == "16000")
        #expect(headers["icy-notice1"]?.contains("Winamp") == true)
    }

    @Test("junk lines and empty values are skipped, not fatal")
    func junkHeaderLines() {
        let headers = StreamDetails.parseIcyHeaders("no colon here\nicy-name:\n: naked value\n")
        #expect(headers.isEmpty)
    }

    // MARK: - Charset fallback

    @Test("decodes UTF-8 titles")
    func decodesUTF8() {
        let bytes = Array("Sigur Rós - Svefn-g-englar".utf8)
        #expect(StreamDetails.decodeIcyText(bytes) == "Sigur Rós - Svefn-g-englar")
    }

    @Test("falls back to Latin-1 for non-UTF-8 bytes")
    func fallsBackToLatin1() {
        // "Café" in Latin-1: 0xE9 alone is invalid UTF-8.
        let bytes: [UInt8] = [0x43, 0x61, 0x66, 0xE9]
        #expect(StreamDetails.decodeIcyText(bytes) == "Café")
    }

    // MARK: - Display helpers

    @Test("codecDisplay folds the profile in when present")
    func codecDisplay() {
        let lc = StreamDetails(
            container: "aac",
            codec: "aac",
            codecProfile: "LC",
            sampleRateHz: 44100,
            channelCount: 2,
            claimedBitrateKbps: 128
        )
        let plain = StreamDetails(
            container: "mp3",
            codec: "mp3",
            codecProfile: nil,
            sampleRateHz: 44100,
            channelCount: 2,
            claimedBitrateKbps: nil
        )
        #expect(lc.codecDisplay == "aac (LC)")
        #expect(plain.codecDisplay == "mp3")
    }
}

// MARK: - FFmpegDecoder detail capture

@Suite("FFmpegDecoder stream details")
struct FFmpegDecoderStreamDetailsTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        try #require(FileManager.default.fileExists(atPath: url.path), "missing fixture \(name)")
        return url
    }

    @Test("captures container, codec, and sample rate for a local MP3")
    func mp3Details() async throws {
        let decoder = try FFmpegDecoder(url: self.fixtureURL("sample.mp3"))
        let details = decoder.streamDetails

        #expect(details.container?.contains("mp3") == true)
        #expect(details.codec == "mp3")
        #expect(details.sampleRateHz > 0)
        #expect(details.channelCount > 0)
        // Local files carry no ICY anything.
        #expect(details.icyName == nil)
        #expect(details.supportsIcyMetadata == false)
        await decoder.close()
    }

    @Test("captures FLAC facts from a lossless fixture")
    func flacDetails() async throws {
        let decoder = try FFmpegDecoder(url: self.fixtureURL("sine-1s-44100-24-stereo.flac"))
        let details = decoder.streamDetails

        #expect(details.codec == "flac")
        #expect(details.sampleRateHz == 44100)
        #expect(details.channelCount == 2)
        await decoder.close()
    }
}
