@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - ReplayGainPumpTests

/// ReplayGain is applied per track inside the buffer pump (#573): each
/// source scales its own samples, so a crossfade keeps each track at its
/// own level, and a live change ramps instead of stepping.
@Suite("ReplayGain - applied per track in the buffer pump (#573)")
struct ReplayGainPumpTests {
    /// 3 s at 44.1 kHz.
    private static let trackFrames: AVAudioFramePosition = 132_300

    // MARK: - PumpSource

    @Test("A source scales every converted sample by its gain")
    func sourceScales() async throws {
        let format = try PCMBuffers.stereo()
        let source = try PumpSource(
            decoder: ScriptedDecoder(format: format, frames: 10000, signal: .constant(0.5)),
            outputFormat: format,
            gain: 0.5
        )
        let buffer = try #require(source.makeReadBuffer(duration: 0.1))
        _ = try await source.read(into: buffer)
        let converted = try #require(try source.convert(buffer))

        for channel in 0 ..< 2 {
            let samples = try PCMBuffers.samples(converted, channel: channel)
            #expect(CrossfadeCurve.maxDeviation(samples, samples.indices) { _ in 0.25 } == 0, "channel \(channel)")
        }
    }

    @Test("A source through a converter is scaled after the conversion")
    func convertedSourceScales() async throws {
        let source = try PumpSource(
            decoder: ScriptedDecoder(format: PCMBuffers.stereo(sampleRate: 48000), frames: nil, signal: .constant(0.5)),
            outputFormat: PCMBuffers.stereo(sampleRate: 44100),
            gain: 2
        )
        #expect(source.hasConverter)
        var last: [Float] = []
        for _ in 0 ..< 3 {
            let buffer = try #require(source.makeReadBuffer(duration: 0.1))
            _ = try await source.read(into: buffer)
            last = try PCMBuffers.samples(#require(try source.convert(buffer)))
        }
        // Past the resampler's start-up, a constant 0.5 comes out at 1.0.
        #expect(CrossfadeCurve.maxDeviation(last, 100 ..< last.count - 100) { _ in 1 } < 1e-3)
    }

    @Test("A gain change ramps across the next buffer, then holds")
    func gainChangeRamps() async throws {
        let format = try PCMBuffers.stereo()
        let source = try PumpSource(
            decoder: ScriptedDecoder(format: format, frames: nil, signal: .constant(0.5)),
            outputFormat: format
        )
        func next() async throws -> [Float] {
            let buffer = try #require(source.makeReadBuffer(duration: 0.1))
            _ = try await source.read(into: buffer)
            return try PCMBuffers.samples(#require(try source.convert(buffer)))
        }

        let unity = try await next()
        #expect(CrossfadeCurve.maxDeviation(unity, unity.indices) { _ in 0.5 } == 0, "unity leaves the samples alone")

        source.gain = 0.5
        let ramp = try await next()
        let first = try #require(ramp.first)
        let last = try #require(ramp.last)
        #expect(first < 0.5 && first > 0.4999, "the ramp starts next to the old level, no step")
        // Float steps over 4410 frames drift a little: -100 dB is exact enough.
        #expect(abs(last - 0.25) < 1e-5, "and ends on the new one")
        let falling = zip(ramp, ramp.dropFirst()).allSatisfy { $0 >= $1 }
        #expect(falling, "falling all the way")

        let held = try await next()
        #expect(CrossfadeCurve.maxDeviation(held, held.indices) { _ in 0.25 } < 1e-6, "then it holds")
    }

    // MARK: - BufferPump

    @Test("setGain reaches only the source that reads the named decoder")
    func setGainTargetsOneSource() async throws {
        let harness = try OfflineRenderHarness()
        let outgoing = ScriptedDecoder(format: harness.format, frames: Self.trackFrames)
        let incoming = ScriptedDecoder(format: harness.format, frames: Self.trackFrames)
        let pump = try harness.makePump(outgoing, gain: 0.5)
        _ = try await pump.armOverlap(decoder: incoming, lengthSeconds: 1, gain: 2) {}

        await pump.setGain(4, forDecoder: incoming)

        #expect(await pump.current.gain == 0.5)
        #expect(await pump.overlap?.incoming.gain == 4)

        await pump.setGain(0.25, forDecoder: outgoing)
        #expect(await pump.current.gain == 0.25)
        #expect(await pump.overlap?.incoming.gain == 4)
        await pump.stop()
    }

    @Test("A pump plays its track at the track's gain")
    func pumpRendersAtGain() async throws {
        let harness = try OfflineRenderHarness()
        let decoder = ScriptedDecoder(format: harness.format, frames: 44100, signal: .constant(0.5))
        let pump = try harness.makePump(decoder, gain: 0.5)
        await pump.start {}
        try await harness.renderToEnd(from: pump)
        await pump.stop()

        #expect(harness.rendered.count == 44100)
        #expect(CrossfadeCurve.maxDeviation(harness.rendered, 0 ..< 44100) { _ in 0.25 } < 1e-6)
    }

    @Test("Through a crossfade each track keeps its own gain")
    func crossfadeKeepsEachGain() async throws {
        let harness = try OfflineRenderHarness()
        // 0.5 at -6 dB and 0.25 at +6 dB: each ends up where the other started.
        let outgoing = ScriptedDecoder(format: harness.format, frames: Self.trackFrames, signal: .constant(0.5))
        let incoming = ScriptedDecoder(format: harness.format, frames: Self.trackFrames, signal: .constant(0.25))
        let pump = try harness.makePump(outgoing, gain: 0.5)
        let armed = try await pump.armOverlap(decoder: incoming, lengthSeconds: 1, gain: 2) {}
        #expect(armed)
        await pump.start {}
        try await harness.renderToEnd(from: pump)
        await pump.stop()

        let out = harness.rendered
        let boundary = 88200
        let length = 44100
        #expect(out.count == 2 * Int(Self.trackFrames) - length)
        #expect(CrossfadeCurve.maxDeviation(out, 0 ..< boundary) { _ in 0.25 } < 1e-6)
        let curve = CrossfadeCurve.maxDeviation(out, boundary ..< boundary + length) {
            CrossfadeCurve.mixed(0.25, 0.5, frame: $0, of: length)
        }
        #expect(curve < 1e-6)
        #expect(CrossfadeCurve.maxDeviation(out, boundary + length ..< out.count) { _ in 0.5 } < 1e-6)
    }
}
