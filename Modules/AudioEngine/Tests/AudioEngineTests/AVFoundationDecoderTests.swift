@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - AVFoundationDecoder tests

@Suite("AVFoundationDecoder")
struct AVFoundationDecoderTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "Missing fixture: \(name)")
    }

    // MARK: - Basic decode

    @Test("WAV: reads expected frame count")
    func wavFrameCount() async throws {
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let decoder = try AVFoundationDecoder(url: url)

        let expectedFrames = AVAudioFrameCount(decoder.sourceFormat.sampleRate * decoder.duration)
        var totalFrames: AVAudioFrameCount = 0
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decoder.sourceFormat, frameCapacity: 4096))
        while true {
            let n = try await decoder.read(into: buf)
            if n == 0 { break }
            totalFrames += n
        }
        await decoder.close()

        // Allow ±5% tolerance for encoder padding.
        let tolerance = Double(expectedFrames) * 0.05
        #expect(abs(Int(totalFrames) - Int(expectedFrames)) < Int(tolerance) + 100)
    }

    @Test("FLAC: duration ≈ 1 s")
    func flacDuration() throws {
        let url = try fixtureURL("sine-1s-44100-24-stereo.flac")
        let decoder = try AVFoundationDecoder(url: url)
        #expect(abs(decoder.duration - 1.0) < 0.05)
    }

    @Test("MP3: opens and has positive duration")
    func mp3Opens() throws {
        let url = try fixtureURL("sample.mp3")
        let decoder = try AVFoundationDecoder(url: url)
        #expect(decoder.duration > 0)
    }

    @Test("AAC M4A: reads frames successfully")
    func aacReads() async throws {
        let url = try fixtureURL("sample-aac.m4a")
        let decoder = try AVFoundationDecoder(url: url)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decoder.sourceFormat, frameCapacity: 4096))
        let n = try await decoder.read(into: buf)
        #expect(n > 0)
        await decoder.close()
    }

    @Test("ALAC M4A: reads frames successfully")
    func alacReads() async throws {
        let url = try fixtureURL("sample-alac.m4a")
        let decoder = try AVFoundationDecoder(url: url)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decoder.sourceFormat, frameCapacity: 4096))
        let n = try await decoder.read(into: buf)
        #expect(n > 0)
        await decoder.close()
    }

    // MARK: - Seek

    @Test("WAV: seek to 0.5 s then read")
    func wavSeek() async throws {
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let decoder = try AVFoundationDecoder(url: url)
        try await decoder.seek(to: 0.5)

        let pos = await decoder.position
        #expect(abs(pos - 0.5) < 0.05, "position after seek should be ≈ 0.5 s, got \(pos)")

        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decoder.sourceFormat, frameCapacity: 4096))
        let n = try await decoder.read(into: buf)
        #expect(n > 0, "should still have frames after seeking to 0.5 s of 1 s file")
        await decoder.close()
    }

    @Test("WAV: seek out-of-range throws")
    func wavSeekOutOfRange() async throws {
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let decoder = try AVFoundationDecoder(url: url)
        await #expect(throws: AudioEngineError.self) {
            try await decoder.seek(to: 999.0)
        }
        await decoder.close()
    }

    // MARK: - Error paths

    @Test("Missing file → fileNotFound")
    func missingFile() throws {
        let url = URL(fileURLWithPath: "/nonexistent/file.wav")
        #expect(throws: AudioEngineError.self) {
            _ = try AVFoundationDecoder(url: url)
        }
    }
}
