import Foundation
import Testing
@testable import AudioEngine

// MARK: - FormatSniffer tests

@Suite("FormatSniffer")
struct FormatSnifferTests {
    private let sniffer = FormatSniffer()

    @Test("WAV magic → .wav")
    func wavMagic() {
        let magic = Data([0x52, 0x49, 0x46, 0x46, // "RIFF"
                          0x00, 0x00, 0x00, 0x00,
                          0x57, 0x41, 0x56, 0x45, // "WAVE"
                          0x66, 0x6D, 0x74, 0x20]) // "fmt "
        #expect(self.sniffer.sniff(bytes: magic) == .wav)
    }

    @Test("FLAC magic → .flac")
    func flacMagic() {
        var magic = Data(count: 16)
        magic[0] = 0x66
        magic[1] = 0x4C
        magic[2] = 0x61
        magic[3] = 0x43 // "fLaC"
        #expect(self.sniffer.sniff(bytes: magic) == .flac)
    }

    @Test("MP3 ID3 magic → .mp3")
    func mp3ID3Magic() {
        var magic = Data(count: 16)
        magic[0] = 0x49
        magic[1] = 0x44
        magic[2] = 0x33 // "ID3"
        #expect(self.sniffer.sniff(bytes: magic) == .mp3)
    }

    @Test("MP3 sync word → .mp3")
    func mp3SyncMagic() {
        var magic = Data(count: 16)
        magic[0] = 0xFF
        magic[1] = 0xFB
        #expect(self.sniffer.sniff(bytes: magic) == .mp3)
    }

    @Test("M4A ftyp magic → .m4a")
    func m4aMagic() {
        var magic = Data(count: 16)
        // "ftyp" at offset 4
        magic[4] = 0x66
        magic[5] = 0x74
        magic[6] = 0x79
        magic[7] = 0x70
        #expect(self.sniffer.sniff(bytes: magic) == .m4a)
    }

    @Test("OGG magic → .ogg")
    func oggMagic() {
        var magic = Data(count: 16)
        magic[0] = 0x4F
        magic[1] = 0x67
        magic[2] = 0x67
        magic[3] = 0x53 // "OggS"
        #expect(self.sniffer.sniff(bytes: magic) == .ogg)
    }

    @Test("DSD/DSF magic → .dsf")
    func dsfMagic() {
        var magic = Data(count: 16)
        magic[0] = 0x44
        magic[1] = 0x53
        magic[2] = 0x44
        magic[3] = 0x20 // "DSD "
        #expect(self.sniffer.sniff(bytes: magic) == .dsf)
    }

    @Test("DFF magic → .dff")
    func dffMagic() {
        var magic = Data(count: 16)
        magic[0] = 0x46
        magic[1] = 0x52
        magic[2] = 0x4D
        magic[3] = 0x38 // "FRM8"
        #expect(self.sniffer.sniff(bytes: magic) == .dff)
    }

    @Test("APE magic → .ape")
    func apeMagic() {
        var magic = Data(count: 16)
        magic[0] = 0x4D
        magic[1] = 0x41
        magic[2] = 0x43
        magic[3] = 0x20 // "MAC "
        #expect(self.sniffer.sniff(bytes: magic) == .ape)
    }

    @Test("WavPack magic → .wavpack")
    func wavpackMagic() {
        var magic = Data(count: 16)
        magic[0] = 0x77
        magic[1] = 0x76
        magic[2] = 0x70
        magic[3] = 0x6B // "wvpk"
        #expect(self.sniffer.sniff(bytes: magic) == .wavpack)
    }

    @Test("Random bytes → .unknown")
    func unknownMagic() {
        let magic = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                          0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F])
        if case .unknown = self.sniffer.sniff(bytes: magic) { /* pass */ } else {
            Issue.record("Expected .unknown for random bytes")
        }
    }

    @Test("Empty data → .unknown")
    func emptyMagic() {
        if case .unknown = self.sniffer.sniff(bytes: Data()) { /* pass */ } else {
            Issue.record("Expected .unknown for empty data")
        }
    }
}

// MARK: - DecoderFactory tests

@Suite("DecoderFactory")
struct DecoderFactoryTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "Missing fixture: \(name)")
    }

    @Test("WAV → AVFoundationDecoder")
    func wavDecodesWithAVFoundation() throws {
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let decoder = try DecoderFactory.make(for: url)
        #expect(decoder is AVFoundationDecoder)
    }

    @Test("FLAC → AVFoundationDecoder")
    func flacDecodesWithAVFoundation() throws {
        let url = try fixtureURL("sine-1s-44100-24-stereo.flac")
        let decoder = try DecoderFactory.make(for: url)
        #expect(decoder is AVFoundationDecoder)
    }

    @Test("MP3 → AVFoundationDecoder")
    func mp3DecodesWithAVFoundation() throws {
        let url = try fixtureURL("sample.mp3")
        let decoder = try DecoderFactory.make(for: url)
        #expect(decoder is AVFoundationDecoder)
    }

    @Test("AAC M4A → AVFoundationDecoder")
    func aacDecodesWithAVFoundation() throws {
        let url = try fixtureURL("sample-aac.m4a")
        let decoder = try DecoderFactory.make(for: url)
        #expect(decoder is AVFoundationDecoder)
    }

    @Test("ALAC M4A → AVFoundationDecoder")
    func alacDecodesWithAVFoundation() throws {
        let url = try fixtureURL("sample-alac.m4a")
        let decoder = try DecoderFactory.make(for: url)
        #expect(decoder is AVFoundationDecoder)
    }

    @Test("OGG → FFmpegDecoder")
    func oggDecodesWithFFmpeg() throws {
        let url = try fixtureURL("sine-1s-48000-stereo.ogg")
        let decoder = try DecoderFactory.make(for: url)
        #expect(decoder is FFmpegDecoder)
    }

    @Test("Opus → FFmpegDecoder")
    func opusDecodesWithFFmpeg() throws {
        let url = try fixtureURL("sine-1s-48000-stereo.opus")
        let decoder = try DecoderFactory.make(for: url)
        #expect(decoder is FFmpegDecoder)
    }

    @Test("Missing file → fileNotFound")
    func missingFile() throws {
        let url = URL(fileURLWithPath: "/nonexistent/audio.wav")
        #expect(throws: AudioEngineError.self) {
            _ = try DecoderFactory.make(for: url)
        }
    }
}
