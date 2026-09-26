@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - CrossfadeRenderTests

/// The proof for #567: render a crossfade offline through a real player node
/// and check that both tracks are in the output at the same time.
///
/// Runs the node alone into the main mixer, without the app's DSP chain (see
/// `OfflineRenderHarness`); the mix happens before the node, so the chain
/// cannot change the result.
@Suite("Crossfade render - both tracks are heard at once (#567)")
struct CrossfadeRenderTests {
    /// 3 s at 44.1 kHz.
    private static let trackFrames: AVAudioFramePosition = 132_300

    @Test("A 1 s crossfade overlaps the tracks on the equal-power curve, with no step at either edge")
    func overlapIsHeard() async throws {
        let harness = try OfflineRenderHarness()
        let outgoing = ScriptedDecoder(format: harness.format, frames: Self.trackFrames, signal: .constant(0.5))
        let incoming = ScriptedDecoder(format: harness.format, frames: Self.trackFrames, signal: .constant(0.25))
        let pump = try harness.makePump(outgoing)
        let clock = harness.clock
        let armed = try await pump.armOverlap(decoder: incoming, lengthSeconds: 1) { clock.recordTransition() }
        #expect(armed)
        await pump.start { clock.recordEnded() }
        try await harness.renderToEnd(from: pump)
        await pump.stop()

        let out = harness.rendered
        let boundary = 88200
        let length = 44100
        #expect(out.count == 2 * Int(Self.trackFrames) - length)

        // Before the overlap: the outgoing track alone.
        #expect(CrossfadeCurve.maxDeviation(out, 0 ..< boundary) { _ in 0.5 } < 1e-6)
        // The overlap: both tracks on the curve, every frame.
        let curve = CrossfadeCurve.maxDeviation(out, boundary ..< boundary + length) {
            CrossfadeCurve.mixed(0.5, 0.25, frame: $0, of: length)
        }
        #expect(curve < 1e-6)
        // The midpoint holds both at -3 dB: 0.5 * 0.7071 + 0.25 * 0.7071.
        // The old dip through silence fails here.
        #expect(abs(out[boundary + length / 2] - 0.5303) < 1e-3)
        // After the overlap: the incoming track alone, at full gain.
        #expect(CrossfadeCurve.maxDeviation(out, boundary + length ..< out.count) { _ in 0.25 } < 1e-6)

        // No click: no step larger than the curve's slope at either edge.
        let slope: Float = 0.75 * .pi / 2 / Float(length)
        #expect(CrossfadeCurve.maxStep(out, boundary - 2 ..< boundary + 2) <= slope + 1e-3)
        #expect(CrossfadeCurve.maxStep(out, boundary + length - 2 ..< boundary + length + 2) <= slope + 1e-3)

        // One transition, when the mix is heard, never before it; one end,
        // for the incoming track only.
        let transitions = clock.transitions
        #expect(transitions.count == 1)
        let heardAt = try #require(transitions.first)
        #expect(heardAt >= boundary)
        #expect(heardAt <= boundary + 4 * 8820)
        #expect(clock.ended == 1)
        // The pump let go of the outgoing track; the incoming one is the
        // engine's to close.
        #expect(outgoing.closeCalls == 1)
        #expect(incoming.closeCalls == 0)
    }

    @Test("Without a crossfade the pump renders its source bit for bit")
    func unarmedIsBitIdentical() async throws {
        let harness = try OfflineRenderHarness()
        let frames = 44100
        let signal = ScriptedDecoder.Signal.sine(frequency: 440, amplitude: 0.5)
        let source = ScriptedDecoder(format: harness.format, frames: AVAudioFramePosition(frames), signal: signal)
        let reference = ScriptedDecoder(format: harness.format, frames: AVAudioFramePosition(frames), signal: signal)
        let pump = try harness.makePump(source)
        await pump.start {}
        try await harness.renderToEnd(from: pump)
        await pump.stop()

        let expected = try PCMBuffers.empty(capacity: frames, format: harness.format)
        _ = try await reference.read(into: expected)
        let samples = try PCMBuffers.samples(expected)
        #expect(harness.rendered == samples)
    }

    @Test("Tracks at different sample rates still overlap after each is converted")
    func differentRatesOverlap() async throws {
        let harness = try OfflineRenderHarness(sampleRate: 44100)
        let outgoing = ScriptedDecoder(format: harness.format, frames: Self.trackFrames, signal: .constant(0.5))
        let incoming = try ScriptedDecoder(
            format: PCMBuffers.stereo(sampleRate: 48000), frames: 144_000, signal: .constant(0.25)
        )
        let pump = try harness.makePump(outgoing)
        let clock = harness.clock
        _ = try await pump.armOverlap(decoder: incoming, lengthSeconds: 1) { clock.recordTransition() }
        await pump.start { clock.recordEnded() }
        try await harness.renderToEnd(from: pump)
        await pump.stop()

        let out = harness.rendered
        let boundary = 88200
        let length = 44100
        // The resampler settles within its first milliseconds, where the
        // incoming gain is still near 0, so the midpoint is exact enough.
        #expect(abs(out[boundary + length / 2] - 0.5303) < 2e-3)
        // After the overlap, away from the converter's end-of-stream tail.
        let steady = boundary + length ..< boundary + length + 44100
        #expect(CrossfadeCurve.maxDeviation(out, steady) { _ in 0.25 } < 1e-3)
        #expect(clock.transitions.count == 1)
    }
}
