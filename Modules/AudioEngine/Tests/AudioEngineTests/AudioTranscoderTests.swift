import Foundation
import Testing
@testable import AudioEngine

/// ADR-088 step 3: the offline transcoder. Verification is re-decode and
/// probe, never golden bytes (encoder output is not bit-stable across FFmpeg
/// versions).
@Suite("AudioTranscoder")
struct AudioTranscoderTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "Missing fixture: \(name)")
    }

    private func makeDestination(for preset: TranscodePreset) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bocan-transcode-\(UUID().uuidString)")
            .appendingPathExtension(preset.fileExtension)
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    @Test("WAV encodes to every preset with the right codec, rate, channels, and duration", arguments: TranscodePreset.allCases)
    func wavEncodesToPreset(preset: TranscodePreset) async throws {
        let source = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let destination = self.makeDestination(for: preset)

        let result = try await AudioTranscoder().transcode(source: source, to: destination, preset: preset)

        #expect(result.size > 0)
        #expect(result.sha256.count == 64)
        #expect(result.bitrateKbps == preset.targetKbps)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.size] as? Int64) == result.size)

        // Re-decode the artifact and probe it.
        let decoder = try FFmpegDecoder(url: destination)
        #expect(abs(decoder.duration - 1.0) < 0.1, "duration drifted: \(decoder.duration)")
        let expectedRate = preset.outputSampleRate(forSourceRate: 44100)
        #expect(decoder.streamDetails.sampleRateHz == Int(expectedRate))
        #expect(decoder.streamDetails.channelCount == 2)
        #expect(decoder.streamDetails.codec?.lowercased().contains(preset.formatName) == true)
        await decoder.close()

        try self.removeIfPresent(destination)
    }

    /// A decoder can change the frame shape mid-stream: an MP3 whose frames
    /// switch between stereo and mono (a damaged file resyncing on a false
    /// header, or a deliberate mode switch) is the real-world case. The
    /// resampler was built for the first shape; feeding it the other one used
    /// to read a plane that does not exist and fault the whole app.
    @Test(
        "a mid-stream channel change reconfigures the resampler instead of faulting",
        arguments: ["sine-1s-44100-stereo-then-mono.mp3", "sine-1s-44100-mono-then-stereo.mp3"]
    )
    func channelChangeMidStream(fixture: String) async throws {
        let source = try fixtureURL(fixture)
        // The output shape is fixed at open from the stream probe, which for
        // a short file reflects whichever frame it decoded last. Whatever it
        // says, the artifact must agree with it, and every frame must land.
        let probe = try FFmpegDecoder(url: source)
        let expectedChannels = probe.streamDetails.channelCount
        await probe.close()
        for preset in [TranscodePreset.opus128, .mp3320] {
            let destination = self.makeDestination(for: preset)

            let result = try await AudioTranscoder().transcode(source: source, to: destination, preset: preset)
            #expect(result.size > 0)

            let decoder = try FFmpegDecoder(url: destination)
            #expect(abs(decoder.duration - 1.0) < 0.2, "duration drifted: \(decoder.duration)")
            #expect(decoder.streamDetails.channelCount == expectedChannels)
            await decoder.close()

            try self.removeIfPresent(destination)
        }
    }

    @Test("metadata tags land in the artifact for both containers", arguments: [TranscodePreset.mp3320, .opus128])
    func metadataRoundTrips(preset: TranscodePreset) async throws {
        let source = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let destination = self.makeDestination(for: preset)

        _ = try await AudioTranscoder().transcode(
            source: source,
            to: destination,
            preset: preset,
            metadata: ["title": "Sine Sweep", "artist": "Bocan Fixture", "album": "Test Tones"]
        )
        let tags = try AudioTranscoder.readMetadata(at: destination)
        #expect(tags["title"] == "Sine Sweep")
        #expect(tags["artist"] == "Bocan Fixture")
        #expect(tags["album"] == "Test Tones")

        try self.removeIfPresent(destination)
    }

    @Test("a lossy source re-encodes cleanly (the transcode-down path)")
    func lossySourceReencodes() async throws {
        let source = try fixtureURL("sample.mp3") // 3 s, 128 kbps CBR
        let destination = self.makeDestination(for: .opus128)

        let result = try await AudioTranscoder().transcode(source: source, to: destination, preset: .opus128)
        #expect(result.size > 0)
        let decoder = try FFmpegDecoder(url: destination)
        #expect(abs(decoder.duration - 3.0) < 0.2)
        #expect(decoder.streamDetails.sampleRateHz == 48000)
        await decoder.close()

        try self.removeIfPresent(destination)
    }

    @Test("cancellation throws and leaves no artifact at the destination")
    func cancellationLeavesNoArtifact() async throws {
        let source = try fixtureURL("sample.mp3")
        let destination = self.makeDestination(for: .mp3320)

        let task = Task {
            try await AudioTranscoder().transcode(source: source, to: destination, preset: .mp3320)
        }
        task.cancel()
        await #expect(throws: (any Error).self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("a corrupt source throws cleanly and leaves no artifact")
    func corruptSourceThrows() async throws {
        let source = try fixtureURL("corrupt.mp3")
        let destination = self.makeDestination(for: .opus128)

        await #expect(throws: (any Error).self) {
            try await AudioTranscoder().transcode(source: source, to: destination, preset: .opus128)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("mid-file damage is tolerated and the healthy audio survives")
    func midFileDamageIsTolerated() async throws {
        // Deterministic damage: stomp 512 bytes in the middle of a FLAC
        // stream (well past STREAMINFO), the shape of the real-world files
        // that play fine but used to fail the transcoder outright.
        let source = try fixtureURL("sine-1s-44100-24-stereo.flac")
        var data = try Data(contentsOf: source)
        let start = data.count / 2
        let end = min(start + 512, data.count)
        data.replaceSubrange(start ..< end, with: Data(repeating: 0x55, count: end - start))
        let damaged = FileManager.default.temporaryDirectory
            .appendingPathComponent("bocan-damaged-\(UUID().uuidString).flac")
        try data.write(to: damaged)
        let destination = self.makeDestination(for: .opus128)

        let result = try await AudioTranscoder().transcode(source: damaged, to: destination, preset: .opus128)

        #expect(result.size > 0)
        let decoder = try FFmpegDecoder(url: destination)
        #expect(decoder.duration > 0.5, "most of the healthy audio survives the damaged region")
        await decoder.close()

        try self.removeIfPresent(destination)
        try self.removeIfPresent(damaged)
    }

    @Test("a missing source throws fileNotFound")
    func missingSourceThrows() async throws {
        let source = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).wav")
        let destination = self.makeDestination(for: .mp3256)

        await #expect(throws: AudioEngineError.self) {
            try await AudioTranscoder().transcode(source: source, to: destination, preset: .mp3256)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("preset vocabulary is stable for the ledger")
    func presetRawValuesAreStable() {
        #expect(TranscodePreset.mp3320.rawValue == "mp3_320")
        #expect(TranscodePreset.mp3256.rawValue == "mp3_256")
        #expect(TranscodePreset.opus192.rawValue == "opus_192")
        #expect(TranscodePreset.opus128.rawValue == "opus_128")
        #expect(TranscodePreset.mp3320.isVBR == false)
        #expect(TranscodePreset.opus128.isVBR == true)
        #expect(TranscodePreset.opus192.outputSampleRate(forSourceRate: 44100) == 48000)
        #expect(TranscodePreset.mp3320.outputSampleRate(forSourceRate: 44100) == 44100)
        #expect(TranscodePreset.mp3320.outputSampleRate(forSourceRate: 96000) == 48000)
    }
}
