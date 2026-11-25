@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - FFmpegSeekTests

/// A seek through `FFmpegDecoder` lands on the exact sample asked for, after
/// the codec's pre-roll (#705). Each case decodes the fixture straight
/// through, seeks a second decoder, and compares what it returns with the
/// straight decode from the target on.
@Suite("FFmpegDecoder sample-exact seek (#705)")
struct FFmpegSeekTests {
    /// One fixture: where to seek and how close the output must stay to a
    /// straight decode.
    struct Case: CustomTestStringConvertible, Sendable {
        let fixture: String
        let target: TimeInterval
        /// Largest sample difference allowed in the compared window.
        let tolerance: Float
        var testDescription: String {
            "\(self.fixture) @ \(self.target) s"
        }
    }

    static let cases: [Case] = [
        // Opus: 3840 samples (80 ms) of pre-roll. The decoder converges over
        // it but is not bit-exact. MP4 lands on the packet, so it gets exactly
        // the pre-roll (measured 0.0053 here, against 0.09 before #705); Ogg
        // lands on a page boundary, which adds more, and comes out exact.
        Case(fixture: "sine-1s-48000-stereo.opus", target: 0.5, tolerance: 1e-4),
        Case(fixture: "opus-in-mp4.m4a", target: 0.12, tolerance: 0.01),
        // Vorbis: no pre-roll value, a page-sized seek granule.
        Case(fixture: "sine-1s-48000-stereo.ogg", target: 0.5, tolerance: 1e-4),
        // DSD64 through the raw DSD path and swresample's filter. DSF seeks
        // land on 4096-sample blocks; the second target is a block boundary,
        // where only the filter's own pre-roll keeps the output exact.
        Case(fixture: "sine-250ms-dsd64-stereo.dsf", target: 0.1, tolerance: 1e-4),
        Case(fixture: "sine-250ms-dsd64-stereo.dsf", target: 32768.0 / 352_800.0, tolerance: 1e-4),
        // No pre-roll: E-AC-3 (multichannel) and WavPack (lossless).
        Case(fixture: "surround-lsrs-1s-48000.eac3", target: 0.5, tolerance: 1e-4),
        Case(fixture: "sine-1s-44100-stereo.wv", target: 0.5, tolerance: 1e-4),
    ]

    /// How far either side of the target the alignment search looks.
    private static let searchRadius = 8
    /// The compared window after the landing point.
    private static let window: TimeInterval = 0.02

    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "Missing fixture: \(name)")
    }

    /// Reads `decoder` to the end, or until `limit` frames, as interleaved
    /// samples.
    private func readAll(_ decoder: FFmpegDecoder, limit: Int = .max) async throws -> [Float] {
        let format = decoder.sourceFormat
        let channels = Int(format.channelCount)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        var out: [Float] = []
        while out.count / channels < limit {
            let n = try await Int(decoder.read(into: buf))
            if n == 0 {
                break
            }
            let data = try #require(buf.floatChannelData)
            for i in 0 ..< n {
                for c in 0 ..< channels {
                    out.append(data[c][i])
                }
            }
        }
        return out
    }

    /// Largest difference between `seeked` and `straight` read from frame
    /// `start`, over `frames` frames.
    private func maxError(_ seeked: [Float], _ straight: [Float], start: Int, frames: Int, channels: Int) -> Float {
        var worst: Float = 0
        for i in 0 ..< frames * channels {
            let j = start * channels + i
            guard i < seeked.count, j >= 0, j < straight.count else { return .infinity }
            worst = max(worst, abs(seeked[i] - straight[j]))
        }
        return worst
    }

    @Test("the first sample after a seek is the target sample", arguments: cases)
    func landsOnTarget(_ testCase: Case) async throws {
        let url = try fixtureURL(testCase.fixture)
        let straightDecoder = try FFmpegDecoder(url: url)
        let straight = try await self.readAll(straightDecoder)
        await straightDecoder.close()

        let decoder = try FFmpegDecoder(url: url)
        let rate = decoder.sourceFormat.sampleRate
        let channels = Int(decoder.sourceFormat.channelCount)
        let frames = Int(Self.window * rate)
        let targetFrame = Int((testCase.target * rate).rounded())
        try await decoder.seek(to: testCase.target)
        #expect(await decoder.position == testCase.target)
        let seeked = try await self.readAll(decoder, limit: frames)
        await decoder.close()
        try #require(seeked.count >= frames * channels, "the seek returned too little audio")

        // The lag whose window matches the straight decode best.
        var best = (lag: Int.max, error: Float.infinity)
        for lag in -Self.searchRadius ... Self.searchRadius {
            let error = self.maxError(seeked, straight, start: targetFrame + lag, frames: frames, channels: channels)
            if error < best.error {
                best = (lag, error)
            }
        }
        #expect(abs(best.lag) <= 1, "landed \(best.lag) samples from the target (error there \(best.error))")
        let atTarget = self.maxError(seeked, straight, start: targetFrame, frames: frames, channels: channels)
        #expect(atTarget <= testCase.tolerance, "error against a straight decode from the target: \(atTarget)")
    }

    @Test("a seek to the start returns the file from its first sample")
    func seekToStart() async throws {
        let url = try fixtureURL("sine-1s-48000-stereo.opus")
        let straightDecoder = try FFmpegDecoder(url: url)
        let straight = try await self.readAll(straightDecoder, limit: 960)
        await straightDecoder.close()

        let decoder = try FFmpegDecoder(url: url)
        _ = try await self.readAll(decoder, limit: 24000)
        try await decoder.seek(to: 0)
        let seeked = try await self.readAll(decoder, limit: 960)
        await decoder.close()
        let error = self.maxError(seeked, straight, start: 0, frames: 960, channels: 2)
        #expect(error <= 1e-4, "error against the file's opening: \(error)")
    }

    @Test("a seek past the last frame ends the stream without throwing")
    func seekToEnd() async throws {
        let decoder = try FFmpegDecoder(url: fixtureURL("sine-1s-48000-stereo.ogg"))
        try await decoder.seek(to: decoder.duration)
        let rest = try await self.readAll(decoder)
        await decoder.close()
        #expect(rest.count / 2 < 64, "more than a few samples after the end: \(rest.count / 2)")
    }

    // MARK: Trim arithmetic

    @Test("a live stream with no length is never trimmed after a seek")
    func liveStreamIsNotTrimmed() {
        // The reconnect seeks a fresh radio decoder to the elapsed listening
        // time, an hour here; trimming to it would drop an hour of audio.
        #expect(FFmpegDecoder.trimTarget(seconds: 3600, sampleRate: 48000, isUnboundedRemoteStream: true) == nil)
        #expect(FFmpegDecoder.trimTarget(seconds: 0.5, sampleRate: 48000, isUnboundedRemoteStream: false) == 24000)
        #expect(FFmpegDecoder.trimTarget(seconds: 0.5, sampleRate: 0, isUnboundedRemoteStream: false) == nil)
    }

    @Test("leading samples to drop: before, across and after the target")
    func leadingSamplesToDrop() {
        #expect(FFmpegDecoder.leadingSamplesToDrop(frameStart: 0, frameCount: 960, target: 2000) == 960)
        #expect(FFmpegDecoder.leadingSamplesToDrop(frameStart: 1920, frameCount: 960, target: 2000) == 80)
        #expect(FFmpegDecoder.leadingSamplesToDrop(frameStart: 2000, frameCount: 960, target: 2000) == 0)
        #expect(FFmpegDecoder.leadingSamplesToDrop(frameStart: 2400, frameCount: 960, target: 2000) == 0)
        #expect(FFmpegDecoder.leadingSamplesToDrop(frameStart: 0, frameCount: 0, target: 2000) == 0)
    }
}
