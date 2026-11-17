import Foundation
import Testing
@testable import AudioEngine

// MARK: - LoadedFileFactsTests

/// ADR-097 slice 7: the engine describes the local file it has open, so the
/// Now Playing badges can show a streamed song's rate, channels and bitrate.
@Suite("Loaded file facts")
struct LoadedFileFactsTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "Missing fixture: \(name)")
    }

    @Test("an MP3 reports its sample rate, channels and a bitrate from its headers")
    func mp3() async throws {
        let engine = AudioEngine()
        try await engine.load(self.fixtureURL("sample.mp3"))
        let facts = try #require(await engine.currentFileFacts)
        #expect(facts.sampleRateHz > 0)
        #expect(facts.channelCount > 0)
        let kbps = try #require(facts.bitrateKbps)
        #expect((8 ... 512).contains(kbps), "an MP3 bitrate, not a size estimate: \(kbps)")
        await engine.stop()
    }

    @Test("a FLAC reports the rate and channels it was written with")
    func flac() async throws {
        let engine = AudioEngine()
        try await engine.load(self.fixtureURL("sine-1s-44100-24-stereo.flac"))
        let facts = try #require(await engine.currentFileFacts)
        #expect(facts.sampleRateHz == 44100)
        #expect(facts.channelCount == 2)
        await engine.stop()
    }

    @Test("with nothing loaded there are no facts")
    func nothingLoaded() async {
        #expect(await AudioEngine().currentFileFacts == nil)
    }
}
