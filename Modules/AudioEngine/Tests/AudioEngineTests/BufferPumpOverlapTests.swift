@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - BufferPumpOverlapTests

/// The pump's crossfade (ADR-095, slice 2b), rendered offline through a real
/// player node: where the mix starts, what happens when a track's duration is
/// wrong, and how disarm, stop and seek treat each phase.
///
/// Every rig crossfades a constant 0.5 outgoing track into a constant 0.25
/// incoming one at 44.1 kHz, so each output frame says which tracks it holds.
@Suite("BufferPump - crossfade overlap")
struct BufferPumpOverlapTests {
    private static let trackFrames: AVAudioFramePosition = 132_300 // 3 s
    private static let bufferFrames = 8820 // one 0.2 s pump buffer

    private struct Rig {
        let harness: OfflineRenderHarness
        let outgoing: ScriptedDecoder
        let incoming: ScriptedDecoder
        let pump: BufferPump
        var clock: RenderClock {
            self.harness.clock
        }
    }

    /// A started pump with a crossfade of `lengthSeconds` armed.
    private static func rig(
        outgoingFrames: AVAudioFramePosition = trackFrames,
        outgoingReports reportedDuration: TimeInterval? = nil,
        lengthSeconds: TimeInterval = 1
    ) async throws -> Rig {
        let harness = try OfflineRenderHarness()
        let outgoing = ScriptedDecoder(
            format: harness.format,
            frames: outgoingFrames,
            signal: .constant(0.5),
            reportedDuration: reportedDuration
        )
        let incoming = ScriptedDecoder(format: harness.format, frames: Self.trackFrames, signal: .constant(0.25))
        let pump = try harness.makePump(outgoing)
        let clock = harness.clock
        let armed = try await pump.armOverlap(decoder: incoming, lengthSeconds: lengthSeconds) {
            clock.recordTransition()
        }
        #expect(armed)
        await pump.start { clock.recordEnded() }
        return Rig(harness: harness, outgoing: outgoing, incoming: incoming, pump: pump)
    }

    /// Renders to just before `boundary`, once the pump has scheduled past it:
    /// the mix has started, but its first frame is not heard yet.
    private static func renderToMixingUnheard(_ rig: Rig, boundary: Int) async throws {
        try await rig.harness.render(boundary - 10000, from: rig.pump)
        try await rig.harness.waitForScheduled(boundary + 1, pump: rig.pump)
        #expect(rig.clock.transitions.isEmpty)
    }

    // MARK: - Where the mix starts

    @Test("A boundary inside a pump buffer is cut there: the mix starts on exactly frame total - length")
    func boundaryInsideABuffer() async throws {
        let rig = try await Self.rig(lengthSeconds: 1.05)
        try await rig.harness.renderToEnd(from: rig.pump)
        await rig.pump.stop()

        let out = rig.harness.rendered
        let length = 46305
        let boundary = Int(Self.trackFrames) - length
        #expect(boundary % Self.bufferFrames != 0, "the test needs a boundary that splits a buffer")
        #expect(CrossfadeCurve.maxDeviation(out, 0 ..< boundary) { _ in 0.5 } < 1e-6)
        // One frame early or late would shift the whole curve by its slope,
        // about 1e-5 per frame here, far above this tolerance.
        let curve = CrossfadeCurve.maxDeviation(out, boundary ..< boundary + length) {
            CrossfadeCurve.mixed(0.5, 0.25, frame: $0, of: length)
        }
        #expect(curve < 1e-6)
        #expect(CrossfadeCurve.maxDeviation(out, boundary + length ..< out.count) { _ in 0.25 } < 1e-6)
        #expect(rig.clock.transitions.count == 1)
        #expect(rig.clock.ended == 1)
    }

    // MARK: - Wrong durations

    @Test("Early end: an outgoing track shorter than it says goes silent inside the overlap, which still completes")
    func earlyEnd() async throws {
        // Says 3 s, has 2.5 s: the mix starts at 2.0 s and the outgoing
        // track runs out halfway through it.
        let rig = try await Self.rig(outgoingFrames: 110_250, outgoingReports: 3)
        try await rig.harness.renderToEnd(from: rig.pump)
        await rig.pump.stop()

        let out = rig.harness.rendered
        let boundary = 88200
        let length = 44100
        let missingFrom = 22050
        #expect(out.count == boundary + Int(Self.trackFrames))
        let withBoth = CrossfadeCurve.maxDeviation(out, boundary ..< boundary + missingFrom) {
            CrossfadeCurve.mixed(0.5, 0.25, frame: $0, of: length)
        }
        #expect(withBoth < 1e-6)
        let incomingOnly = CrossfadeCurve.maxDeviation(out, boundary + missingFrom ..< boundary + length) {
            CrossfadeCurve.mixed(0, 0.25, frame: $0 + missingFrom, of: length)
        }
        #expect(incomingOnly < 1e-6)
        #expect(CrossfadeCurve.maxDeviation(out, boundary + length ..< out.count) { _ in 0.25 } < 1e-6)
        #expect(rig.clock.transitions.count == 1)
        #expect(rig.clock.ended == 1, "the outgoing track's end must not end playback")
    }

    @Test("Late end: an outgoing track longer than it says has its tail dropped when the overlap ends")
    func lateEnd() async throws {
        // Says 2.5 s, has 3 s: the mix runs from 1.5 s to 2.5 s, and the
        // outgoing track's last 0.5 s is never heard.
        let rig = try await Self.rig(outgoingReports: 2.5)
        try await rig.harness.renderToEnd(from: rig.pump)
        await rig.pump.stop()

        let out = rig.harness.rendered
        let boundary = 66150
        let length = 44100
        #expect(out.count == boundary + Int(Self.trackFrames))
        let curve = CrossfadeCurve.maxDeviation(out, boundary ..< boundary + length) {
            CrossfadeCurve.mixed(0.5, 0.25, frame: $0, of: length)
        }
        #expect(curve < 1e-6)
        #expect(CrossfadeCurve.maxDeviation(out, boundary + length ..< out.count) { _ in 0.25 } < 1e-6)
        #expect(rig.clock.transitions.count == 1)
        #expect(rig.clock.ended == 1)
        #expect(rig.outgoing.closeCalls == 1)
    }

    // MARK: - Disarm

    @Test("Disarming before the mix closes the incoming track, and the outgoing one plays out unmixed")
    func disarmBeforeMix() async throws {
        let rig = try await Self.rig()
        try await rig.harness.render(22050, from: rig.pump)

        #expect(await rig.pump.disarmOverlap() == .dropped)
        #expect(rig.incoming.closeCalls == 1)

        try await rig.harness.renderToEnd(from: rig.pump)
        await rig.pump.stop()
        let out = rig.harness.rendered
        #expect(out.count == Int(Self.trackFrames))
        #expect(CrossfadeCurve.maxDeviation(out, 0 ..< out.count) { _ in 0.5 } < 1e-6)
        #expect(rig.clock.transitions.isEmpty)
        #expect(rig.clock.ended == 1)
    }

    @Test("Once mixing has started, disarming is refused and the crossfade completes")
    func disarmWhileMixing() async throws {
        let rig = try await Self.rig()
        try await Self.renderToMixingUnheard(rig, boundary: 88200)

        #expect(await rig.pump.disarmOverlap() == .tooLate)

        try await rig.harness.renderToEnd(from: rig.pump)
        await rig.pump.stop()
        #expect(rig.clock.transitions.count == 1)
        #expect(rig.harness.rendered.count == 2 * Int(Self.trackFrames) - 44100)
    }

    // MARK: - Stop

    @Test("Stopping before the mix is heard closes only the incoming track")
    func stopBeforeHeard() async throws {
        let rig = try await Self.rig()
        try await Self.renderToMixingUnheard(rig, boundary: 88200)

        let heard = await rig.pump.stop()

        #expect(!heard)
        #expect(rig.incoming.closeCalls == 1)
        #expect(rig.outgoing.closeCalls == 0, "the outgoing track is still the engine's decoder")
        #expect(rig.clock.transitions.isEmpty)
    }

    @Test("Stopping after the mix is heard closes only the outgoing track")
    func stopAfterHeard() async throws {
        let rig = try await Self.rig()
        try await rig.harness.render(88200 + 20000, from: rig.pump)
        try await rig.clock.waitForTransitions(1)

        let heard = await rig.pump.stop()

        #expect(heard)
        #expect(rig.outgoing.closeCalls == 1)
        #expect(rig.incoming.closeCalls == 0, "the incoming track is now the engine's decoder")
    }

    // MARK: - Seek

    @Test("A seek before the mix is heard is for the outgoing track, and the crossfade re-arms from there")
    func seekBeforeHeardRearms() async throws {
        let rig = try await Self.rig()
        try await Self.renderToMixingUnheard(rig, boundary: 88200)

        let heard = try await rig.pump.reschedule(to: 0.5)
        rig.harness.restart()
        try await rig.harness.renderToEnd(from: rig.pump)
        await rig.pump.stop()

        #expect(!heard)
        #expect(rig.outgoing.seekTargets == [0.5])
        #expect(rig.incoming.seekTargets == [0], "the incoming track rewinds for the next attempt")
        // The node restarts at file frame 22050, so the boundary is 22050 earlier.
        let out = rig.harness.rendered
        let boundary = 66150
        let length = 44100
        #expect(CrossfadeCurve.maxDeviation(out, 0 ..< boundary) { _ in 0.5 } < 1e-6)
        let curve = CrossfadeCurve.maxDeviation(out, boundary ..< boundary + length) {
            CrossfadeCurve.mixed(0.5, 0.25, frame: $0, of: length)
        }
        #expect(curve < 1e-6)
        #expect(rig.clock.transitions.count == 1)
        #expect(rig.clock.ended == 1)
    }

    @Test("A seek after the mix is heard is for the incoming track, and the outgoing one is dropped")
    func seekAfterHeard() async throws {
        let rig = try await Self.rig()
        try await rig.harness.render(88200 + 20000, from: rig.pump)
        try await rig.clock.waitForTransitions(1)

        let heard = try await rig.pump.reschedule(to: 1.0)
        rig.harness.restart()
        try await rig.harness.renderToEnd(from: rig.pump)
        await rig.pump.stop()

        #expect(heard)
        #expect(rig.outgoing.closeCalls == 1)
        #expect(rig.incoming.seekTargets == [1.0])
        let out = rig.harness.rendered
        #expect(out.count == Int(Self.trackFrames) - 44100)
        #expect(CrossfadeCurve.maxDeviation(out, 0 ..< out.count) { _ in 0.25 } < 1e-6)
        #expect(rig.clock.ended == 1)
    }

    @Test("A seek into the window starts a shorter mix at once")
    func seekIntoWindowShortensTheMix() async throws {
        // A 2 s crossfade, and a seek to 1.5 s: 1.5 s of the outgoing track
        // is left, so the mix starts at once and lasts 1.5 s.
        let rig = try await Self.rig(lengthSeconds: 2)
        _ = try await rig.pump.reschedule(to: 1.5)
        rig.harness.restart()
        try await rig.harness.renderToEnd(from: rig.pump)
        await rig.pump.stop()

        let out = rig.harness.rendered
        let length = 66150
        let curve = CrossfadeCurve.maxDeviation(out, 0 ..< length) {
            CrossfadeCurve.mixed(0.5, 0.25, frame: $0, of: length)
        }
        #expect(curve < 1e-6)
        #expect(CrossfadeCurve.maxDeviation(out, length ..< out.count) { _ in 0.25 } < 1e-6)
        #expect(rig.clock.transitions.count == 1)
    }

    @Test("A seek into the last second hands over gapless: too little is left to mix")
    func seekIntoLastSecondIsGapless() async throws {
        let rig = try await Self.rig()
        _ = try await rig.pump.reschedule(to: 2.5)
        rig.harness.restart()
        try await rig.harness.renderToEnd(from: rig.pump)
        await rig.pump.stop()

        let out = rig.harness.rendered
        let tail = 22050
        #expect(out.count == tail + Int(Self.trackFrames))
        #expect(CrossfadeCurve.maxDeviation(out, 0 ..< tail) { _ in 0.5 } < 1e-6)
        #expect(CrossfadeCurve.maxDeviation(out, tail ..< out.count) { _ in 0.25 } < 1e-6)
        let heardAt = try #require(rig.clock.transitions.first)
        #expect(heardAt >= tail)
        #expect(rig.clock.ended == 1)
    }

    // MARK: - Refusals

    @Test("A CUE segment or a pump that has ended cannot take a crossfade")
    func armingRefused() async throws {
        let harness = try OfflineRenderHarness()
        let segment = try BufferPump(
            decoder: ScriptedDecoder(format: harness.format, frames: nil),
            playerNode: harness.node,
            outputFormat: harness.format,
            maxDuration: 1
        )
        let segmentArmed = try await segment.armOverlap(
            decoder: ScriptedDecoder(format: harness.format, frames: nil), lengthSeconds: 1
        ) {}
        #expect(!segmentArmed)

        let ended = try harness.makePump(ScriptedDecoder(format: harness.format, frames: 0))
        await ended.start {}
        try await harness.renderToEnd(from: ended)
        let endedArmed = try await ended.armOverlap(
            decoder: ScriptedDecoder(format: harness.format, frames: nil), lengthSeconds: 1
        ) {}
        #expect(!endedArmed)
        await ended.stop()
    }
}
