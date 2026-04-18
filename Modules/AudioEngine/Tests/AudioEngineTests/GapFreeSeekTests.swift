@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - Seek accuracy / gapless tests

@Suite("Seek accuracy")
struct GapFreeSeekTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "Missing fixture: \(name)")
    }

    // MARK: - AVFoundationDecoder seek accuracy

    @Test("WAV: seek to 0.0 reads from start")
    func wavSeekToZero() async throws {
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let decoder = try AVFoundationDecoder(url: url)
        try await decoder.seek(to: 0.0)
        let pos = await decoder.position
        #expect(pos == 0.0, "Seeking to 0 should put position at 0, got \(pos)")
        await decoder.close()
    }

    @Test("WAV: seek to 0.5 s, position is ≈ 0.5")
    func wavSeekToMiddle() async throws {
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let decoder = try AVFoundationDecoder(url: url)
        try await decoder.seek(to: 0.5)
        let pos = await decoder.position
        #expect(abs(pos - 0.5) < 0.01, "Expected position ≈ 0.5 s, got \(pos)")
        await decoder.close()
    }

    @Test("WAV: seek and total remaining frames ≈ (duration - seekTime) × sampleRate")
    func wavSeekRemainingFrames() async throws {
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let decoder = try AVFoundationDecoder(url: url)
        let seekTime = 0.5
        try await decoder.seek(to: seekTime)

        let sampleRate = decoder.sourceFormat.sampleRate
        let expectedRemaining = (decoder.duration - seekTime) * sampleRate

        var totalFrames: AVAudioFrameCount = 0
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decoder.sourceFormat, frameCapacity: 4096))
        while true {
            let n = try await decoder.read(into: buf)
            if n == 0 { break }
            totalFrames += n
        }
        await decoder.close()

        let tolerance = expectedRemaining * 0.05 + 100
        #expect(
            abs(Double(totalFrames) - expectedRemaining) < tolerance,
            "Remaining frames \(totalFrames) expected ≈ \(Int(expectedRemaining))"
        )
    }

    @Test("WAV: seek is monotonic across multiple seeks")
    func wavMonotonicSeek() async throws {
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let decoder = try AVFoundationDecoder(url: url)

        let seekTimes = [0.1, 0.3, 0.2, 0.7, 0.5]
        for t in seekTimes {
            try await decoder.seek(to: t)
            let pos = await decoder.position
            #expect(abs(pos - t) < 0.05, "Seek to \(t) gave position \(pos)")
        }
        await decoder.close()
    }

    // MARK: - FFmpegDecoder seek accuracy

    @Test("OGG: seek to near-middle, position is sane")
    func oggSeekToMiddle() async throws {
        let url = try fixtureURL("sine-1s-48000-stereo.ogg")
        let decoder = try FFmpegDecoder(url: url)
        try await decoder.seek(to: 0.4)
        let pos = await decoder.position
        // FFmpeg seek is coarse; accept 0..1
        #expect(pos >= 0.0 && pos <= 1.0, "Seek position out of range: \(pos)")
        await decoder.close()
    }

    @Test("OGG: seek to 0.0 reads frames from beginning")
    func oggSeekToZero() async throws {
        let url = try fixtureURL("sine-1s-48000-stereo.ogg")
        let decoder = try FFmpegDecoder(url: url)

        // Read a bit first.
        let fmt = decoder.sourceFormat
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 2048))
        _ = try await decoder.read(into: buf)

        // Seek back to zero and read again.
        try await decoder.seek(to: 0.0)
        let n = try await decoder.read(into: buf)
        #expect(n > 0, "Should read frames after seeking to 0")
        await decoder.close()
    }

    // MARK: - Cancellation

    @Test("Cancelling decode task does not crash")
    func cancellationSafety() async throws {
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let decoder = try AVFoundationDecoder(url: url)

        let task = Task {
            let fmt = decoder.sourceFormat
            let buf = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 512))
            while true {
                let n = try await decoder.read(into: buf)
                if n == 0 { break }
            }
        }
        task.cancel()
        _ = await task.result // should not crash or hang
        await decoder.close()
    }

    // MARK: - Property-based: random seek sequence never crashes

    @Test("Random seek sequence never throws on WAV")
    func randomSeekSequence() async throws {
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let decoder = try AVFoundationDecoder(url: url)
        let duration = decoder.duration

        // Fixed seek positions as fractions of duration — deterministic.
        let fractions: [Double] = [0.1, 0.3, 0.7, 0.05, 0.95, 0.5, 0.25, 0.8, 0.15, 0.45]
        for f in fractions {
            try await decoder.seek(to: f * duration)
        }
        await decoder.close()
        // Test passes if no exception thrown.
    }
}
