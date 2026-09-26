@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - BufferPumpQueuedOverlapTests

/// A crossfade armed while the one before it still mixes its tail (ADR-095).
///
/// A track shorter than about twice the crossfade plus the arming margin is
/// armed for its own crossfade before the crossfade into it has finished
/// mixing. The pump used to refuse that arm, so the boundary fell back to
/// gapless: every second boundary of a run of short tracks.
///
/// Every rig crossfades a constant 0.5 track A into a constant 0.25 track B
/// with a 1.5 s overlap, hears it, and then arms B into a constant 0.125
/// track C with a 1 s overlap while A's tail is still being mixed. All tracks
/// are 3 s at 44.1 kHz.
@Suite("BufferPump - crossfade queued behind a mix")
struct BufferPumpQueuedOverlapTests {
    private static let trackFrames = 132_300 // 3 s
    /// Where the A to B mix starts and how long it lasts, in output frames.
    private static let firstBoundary = 66150
    private static let firstLength = 66150
    /// The B to C mix, 2 s into B.
    private static let secondBoundary = firstBoundary + 88200
    private static let secondLength = 44100

    private struct Rig {
        let harness: OfflineRenderHarness
        let first: ScriptedDecoder
        let second: ScriptedDecoder
        let third: ScriptedDecoder
        let pump: BufferPump
        let queued: Bool
        var clock: RenderClock {
            self.harness.clock
        }
    }

    /// A pump mixing A into B with the transition heard, and C armed.
    private static func rig() async throws -> Rig {
        let harness = try OfflineRenderHarness()
        let frames = AVAudioFramePosition(Self.trackFrames)
        let first = ScriptedDecoder(format: harness.format, frames: frames, signal: .constant(0.5))
        let second = ScriptedDecoder(format: harness.format, frames: frames, signal: .constant(0.25))
        let third = ScriptedDecoder(format: harness.format, frames: frames, signal: .constant(0.125))
        let pump = try harness.makePump(first)
        let clock = harness.clock
        let firstArmed = try await pump.armOverlap(decoder: second, lengthSeconds: 1.5) { clock.recordTransition() }
        #expect(firstArmed)
        await pump.start { clock.recordEnded() }

        try await harness.render(Self.firstBoundary + 10000, from: pump)
        try await clock.waitForTransitions(1)
        // The pump runs at most four buffers (35 280 frames) ahead of the
        // render, so it is still mixing A's tail here.
        let scheduled = await Int(pump.framesScheduledSinceFlush)
        #expect(scheduled < Self.firstBoundary + Self.firstLength)

        let queued = try await pump.armOverlap(decoder: third, lengthSeconds: 1) { clock.recordTransition() }
        return Rig(harness: harness, first: first, second: second, third: third, pump: pump, queued: queued)
    }

    @Test("A crossfade armed during a heard mix is queued, and mixes at its own boundary")
    func queuedCrossfadeMixes() async throws {
        let rig = try await Self.rig()
        #expect(rig.queued)
        try await rig.harness.renderToEnd(from: rig.pump)
        await rig.pump.stop()

        let out = rig.harness.rendered
        #expect(out.count == Self.secondBoundary + Self.trackFrames)
        let firstMix = CrossfadeCurve.maxDeviation(out, Self.firstBoundary ..< Self.firstBoundary + Self.firstLength) {
            CrossfadeCurve.mixed(0.5, 0.25, frame: $0, of: Self.firstLength)
        }
        #expect(firstMix < 1e-6, "the queued arm must not disturb the running mix")
        let betweenMixes = Self.firstBoundary + Self.firstLength ..< Self.secondBoundary
        #expect(CrossfadeCurve.maxDeviation(out, betweenMixes) { _ in 0.25 } < 1e-6)
        let secondMix = CrossfadeCurve.maxDeviation(out, Self.secondBoundary ..< Self.secondBoundary + Self.secondLength) {
            CrossfadeCurve.mixed(0.25, 0.125, frame: $0, of: Self.secondLength)
        }
        #expect(secondMix < 1e-6)
        let tail = Self.secondBoundary + Self.secondLength ..< out.count
        #expect(CrossfadeCurve.maxDeviation(out, tail) { _ in 0.125 } < 1e-6)
        #expect(rig.clock.transitions.count == 2)
        let secondHeardAt = try #require(rig.clock.transitions.last)
        #expect(secondHeardAt >= Self.secondBoundary)
        #expect(rig.clock.ended == 1)
        #expect(rig.first.closeCalls == 1)
        #expect(rig.second.closeCalls == 1)
    }

    @Test("Disarming drops the queued crossfade, never the mix it waits behind")
    func disarmDropsTheQueuedOne() async throws {
        let rig = try await Self.rig()

        #expect(await rig.pump.disarmOverlap() == .dropped)
        #expect(rig.third.closeCalls == 1)

        try await rig.harness.renderToEnd(from: rig.pump)
        await rig.pump.stop()
        let out = rig.harness.rendered
        #expect(out.count == Self.firstBoundary + Self.trackFrames)
        let tail = Self.firstBoundary + Self.firstLength ..< out.count
        #expect(CrossfadeCurve.maxDeviation(out, tail) { _ in 0.25 } < 1e-6)
        #expect(rig.clock.transitions.count == 1)
    }

    /// The engine completes its pending crossfade when `stop` says heard.
    /// With a queued crossfade, that pending one is the queued one, which is
    /// not heard.
    @Test("Stopping with a queued crossfade reports it not heard and closes what only the pump holds")
    func stopWithQueued() async throws {
        let rig = try await Self.rig()

        let heard = await rig.pump.stop()

        #expect(!heard)
        #expect(rig.first.closeCalls == 1)
        #expect(rig.second.closeCalls == 0, "track B is the engine's decoder")
        #expect(rig.third.closeCalls == 1)
    }

    @Test("A seek during the tail is for track B, and the queued crossfade arms from there")
    func seekArmsTheQueuedOne() async throws {
        let rig = try await Self.rig()

        let heard = try await rig.pump.reschedule(to: 0.5)
        rig.harness.restart()
        try await rig.harness.renderToEnd(from: rig.pump)
        await rig.pump.stop()

        #expect(!heard, "the engine must not complete the queued crossfade")
        #expect(rig.second.seekTargets == [0.5])
        #expect(rig.first.closeCalls == 1)
        // From B's 0.5 s: 1.5 s of B, the 1 s mix, then the rest of C.
        let out = rig.harness.rendered
        let boundary = 66150
        #expect(out.count == boundary + Self.trackFrames)
        #expect(CrossfadeCurve.maxDeviation(out, 0 ..< boundary) { _ in 0.25 } < 1e-6)
        let curve = CrossfadeCurve.maxDeviation(out, boundary ..< boundary + Self.secondLength) {
            CrossfadeCurve.mixed(0.25, 0.125, frame: $0, of: Self.secondLength)
        }
        #expect(curve < 1e-6)
        #expect(rig.clock.transitions.count == 2)
        #expect(rig.clock.ended == 1)
    }
}
