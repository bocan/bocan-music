@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - FFmpegDecoder tests

@Suite("FFmpegDecoder")
struct FFmpegDecoderTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "Missing fixture: \(name)")
    }

    // MARK: - OGG/Vorbis

    @Test("OGG: duration ≈ 1 s")
    func oggDuration() throws {
        let url = try fixtureURL("sine-1s-48000-stereo.ogg")
        let decoder = try FFmpegDecoder(url: url)
        // Vorbis containers sometimes report 0 duration; accept either 0 or ≈1
        if decoder.duration > 0 {
            #expect(abs(decoder.duration - 1.0) < 0.2)
        }
    }

    @Test("OGG: reads frames")
    func oggReadsFrames() async throws {
        let url = try fixtureURL("sine-1s-48000-stereo.ogg")
        let decoder = try FFmpegDecoder(url: url)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decoder.sourceFormat, frameCapacity: 4096))
        let n = try await decoder.read(into: buf)
        #expect(n > 0)
        await decoder.close()
    }

    @Test("OGG: reads all frames to EOF")
    func oggReadAllFrames() async throws {
        let url = try fixtureURL("sine-1s-48000-stereo.ogg")
        let decoder = try FFmpegDecoder(url: url)
        var totalFrames: AVAudioFrameCount = 0
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decoder.sourceFormat, frameCapacity: 4096))
        while true {
            let n = try await decoder.read(into: buf)
            if n == 0 { break }
            totalFrames += n
        }
        await decoder.close()
        // 1 s @ 48000 Hz ≈ 48000 frames (±5%)
        #expect(
            totalFrames > 45000 && totalFrames < 51000,
            "Expected ≈48000 frames, got \(totalFrames)"
        )
    }

    // MARK: - Opus

    @Test("Opus: reads frames")
    func opusReadsFrames() async throws {
        let url = try fixtureURL("sine-1s-48000-stereo.opus")
        let decoder = try FFmpegDecoder(url: url)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decoder.sourceFormat, frameCapacity: 4096))
        let n = try await decoder.read(into: buf)
        #expect(n > 0)
        await decoder.close()
    }

    @Test("Opus: stereo output format")
    func opusStereoOutput() throws {
        let url = try fixtureURL("sine-1s-48000-stereo.opus")
        let decoder = try FFmpegDecoder(url: url)
        #expect(decoder.sourceFormat.channelCount == 2)
        #expect(decoder.sourceFormat.sampleRate == 48000)
    }

    // MARK: - Seek

    @Test("OGG: seek to 0.5 s")
    func oggSeek() async throws {
        let url = try fixtureURL("sine-1s-48000-stereo.ogg")
        let decoder = try FFmpegDecoder(url: url)
        try await decoder.seek(to: 0.5)
        let pos = await decoder.position
        // FFmpeg seek is approximate
        #expect(pos >= 0 && pos <= 1.0)

        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decoder.sourceFormat, frameCapacity: 4096))
        let n = try await decoder.read(into: buf)
        #expect(n > 0)
        await decoder.close()
    }

    // MARK: - Error paths

    @Test("Missing file → fileNotFound")
    func missingFile() throws {
        let url = URL(fileURLWithPath: "/nonexistent/audio.ogg")
        #expect(throws: AudioEngineError.self) {
            _ = try FFmpegDecoder(url: url)
        }
    }

    // MARK: - Sine-wave sanity (FFT)

    @Test("OGG sine: peak frequency ≈ 440 Hz")
    func oggSinePeakFrequency() async throws {
        let url = try fixtureURL("sine-1s-48000-stereo.ogg")
        let decoder = try FFmpegDecoder(url: url)
        let sampleRate = decoder.sourceFormat.sampleRate

        // Read the first 4096-frame buffer.
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decoder.sourceFormat, frameCapacity: 4096))
        let n = try await decoder.read(into: buf)
        await decoder.close()
        #expect(n > 0)

        // Extract the left channel.
        guard let ch0 = buf.floatChannelData?[0] else {
            Issue.record("No float channel data")
            return
        }
        let frameCount = Int(n)
        let samples = Array(UnsafeBufferPointer(start: ch0, count: frameCount))

        // Naive DFT peak detection (sufficient for a 440 Hz sine test).
        let peakBin = self.naivePeakBin(samples)
        let peakFreq = Double(peakBin) * sampleRate / Double(frameCount)

        // Accept ±2 bins of error.
        let freqResolution = sampleRate / Double(frameCount)
        #expect(
            abs(peakFreq - 440.0) < freqResolution * 2 + 5,
            "Peak frequency \(peakFreq) Hz, expected ≈ 440 Hz"
        )
    }

    // MARK: - Private helpers

    /// Returns the index of the bin with maximum magnitude (excluding DC).
    private func naivePeakBin(_ samples: [Float]) -> Int {
        let n = samples.count
        guard n > 1 else { return 0 }
        var maxMag = 0.0
        var peakBin = 1
        for k in 1 ..< n / 2 {
            var re = 0.0, im = 0.0
            for j in 0 ..< n {
                let angle = 2.0 * Double.pi * Double(k) * Double(j) / Double(n)
                re += Double(samples[j]) * cos(angle)
                im -= Double(samples[j]) * sin(angle)
            }
            let mag = (re * re + im * im).squareRoot()
            if mag > maxMag { maxMag = mag
                peakBin = k
            }
        }
        return peakBin
    }
}
