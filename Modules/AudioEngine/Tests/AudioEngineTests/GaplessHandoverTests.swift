@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - GaplessHandoverTests

/// Plain gapless as a hand-over inside the playing pump (#574): an overlap of
/// length 0, rendered offline through a real player node. The next track
/// follows the last frame of the current one, and the transition fires when
/// the next track is heard, not when the current decoder reaches its end,
/// which is four buffers (about 0.8 s) earlier.
@Suite("BufferPump - gapless hand-over (#574)")
struct GaplessHandoverTests {
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

    /// A started pump, a constant 0.5 track, with a hand-over armed into a
    /// constant 0.25 track.
    private static func rig() async throws -> Rig {
        let harness = try OfflineRenderHarness()
        let outgoing = ScriptedDecoder(format: harness.format, frames: Self.trackFrames, signal: .constant(0.5))
        let incoming = ScriptedDecoder(format: harness.format, frames: Self.trackFrames, signal: .constant(0.25))
        let pump = try harness.makePump(outgoing)
        let clock = harness.clock
        let armed = try await pump.armOverlap(decoder: incoming, lengthSeconds: 0) { clock.recordTransition() }
        #expect(armed)
        await pump.start { clock.recordEnded() }
        return Rig(harness: harness, outgoing: outgoing, incoming: incoming, pump: pump)
    }

    @Test("A hand-over never mixes: it waits for the outgoing track's end from the start")
    func armsStraightToHandover() async throws {
        let rig = try await Self.rig()
        let phase = try #require(await rig.pump.overlap?.phase)
        guard case .armedLate = phase else {
            Issue.record("a zero-length overlap should start as a hand-over, got \(phase)")
            return
        }
        #expect(await rig.pump.overlap?.lengthFrames == 0)
        await rig.pump.stop()
    }

    @Test("The next track starts on the frame after the last one, and its transition fires when it is heard")
    func handoverIsGaplessAndHeard() async throws {
        let rig = try await Self.rig()
        try await rig.harness.renderToEnd(from: rig.pump)
        await rig.pump.stop()

        let out = rig.harness.rendered
        let boundary = Int(Self.trackFrames)
        // No gap and no overlap: exactly both tracks, back to back.
        #expect(out.count == 2 * boundary)
        #expect(CrossfadeCurve.maxDeviation(out, 0 ..< boundary) { _ in 0.5 } < 1e-6)
        #expect(CrossfadeCurve.maxDeviation(out, boundary ..< out.count) { _ in 0.25 } < 1e-6)

        // The old handoff fired when the outgoing decoder ended, four buffers
        // before this boundary. Now it fires once the boundary is heard.
        let transitions = rig.clock.transitions
        #expect(transitions.count == 1)
        let heardAt = try #require(transitions.first)
        #expect(heardAt >= boundary)
        #expect(heardAt <= boundary + 4 * Self.bufferFrames)
        #expect(rig.clock.ended == 1, "one end, for the incoming track only")
        #expect(rig.outgoing.closeCalls == 1, "the pump let go of the outgoing track once it was heard out")
        #expect(rig.incoming.closeCalls == 0, "the incoming track is the engine's to close")
    }

    @Test("A seek after the hand-over but before it is heard goes back to the outgoing track and re-arms")
    func seekBeforeHeardRearms() async throws {
        let rig = try await Self.rig()
        // The outgoing feed has ended and the incoming track is being
        // scheduled, but the listener is still inside the outgoing track.
        // Rendered to about one buffer short of the end, so the four-buffer
        // window reaches past it.
        try await rig.harness.render(Int(Self.trackFrames) - 10000, from: rig.pump)
        try await rig.harness.waitForScheduled(Int(Self.trackFrames) + 1, pump: rig.pump)
        #expect(rig.clock.transitions.isEmpty)

        let heard = try await rig.pump.reschedule(to: 2.0)
        let phase = try #require(await rig.pump.overlap?.phase)
        guard case .armedLate = phase else {
            Issue.record("a re-armed hand-over should still be a hand-over, got \(phase)")
            return
        }
        rig.harness.restart()
        try await rig.harness.renderToEnd(from: rig.pump)
        await rig.pump.stop()

        #expect(!heard)
        #expect(rig.outgoing.seekTargets == [2.0])
        #expect(rig.incoming.seekTargets == [0], "the incoming track rewinds for the next hand-over")
        let out = rig.harness.rendered
        let tail = 44100
        #expect(out.count == tail + Int(Self.trackFrames))
        #expect(CrossfadeCurve.maxDeviation(out, 0 ..< tail) { _ in 0.5 } < 1e-6)
        #expect(CrossfadeCurve.maxDeviation(out, tail ..< out.count) { _ in 0.25 } < 1e-6)
        let heardAt = try #require(rig.clock.transitions.first)
        #expect(heardAt >= tail)
        #expect(rig.clock.transitions.count == 1)
    }
}

// MARK: - EngineGaplessHandoverTests

/// The engine's side of #574: which way it prepares a boundary. None of these
/// play audio; the audio is proved by `GaplessHandoverTests` above.
@Suite("AudioEngine - gapless preparation (#574)")
struct EngineGaplessHandoverTests {
    private func fixtureURL() throws -> URL {
        let url = Bundle.module.url(
            forResource: "sine-1s-44100-16-stereo.wav", withExtension: nil, subdirectory: "Fixtures"
        )
        return try #require(url)
    }

    /// An engine with a track loaded and a pump in place, as `play` leaves it.
    private func playingEngine() async throws -> (AudioEngine, BufferPump) {
        let engine = AudioEngine()
        try await engine.load(self.fixtureURL())
        let decoder = try #require(await engine.decoder)
        let pump = try await BufferPump(
            decoder: decoder,
            playerNode: engine.graph.playerNode,
            outputFormat: PCMBuffers.stereo()
        )
        await engine.installPumpForHandoverTest(pump)
        return (engine, pump)
    }

    @Test("With a pump playing, gapless is a hand-over in that pump, with no second pump")
    func gaplessHandsOverInThePump() async throws {
        let (engine, pump) = try await self.playingEngine()

        let preparation = try await engine.enableGaplessNext(url: self.fixtureURL()) {}

        #expect(preparation == .handover)
        #expect(await engine.pendingNextPump == nil)
        #expect(await engine.pendingCrossfade != nil)
        #expect(await pump.overlap?.lengthFrames == 0)

        await engine.cancelGaplessNext()
        #expect(await engine.pendingCrossfade == nil)
        #expect(await pump.overlap == nil)
        await pump.stop()
    }

    @Test("A crossfade too short to mix falls back to a hand-over, not a second pump")
    func shortCrossfadeHandsOver() async throws {
        let (engine, pump) = try await self.playingEngine()

        // Both tracks are 1 s long: half of either is under the 1 s minimum.
        let preparation = try await engine.enableCrossfadeNext(url: self.fixtureURL(), overlapSeconds: 5) {}

        #expect(preparation == .handover)
        #expect(await engine.pendingNextPump == nil)
        #expect(await pump.overlap?.lengthFrames == 0)
        await engine.cancelGaplessNext()
        await pump.stop()
    }

    @Test("With nothing playing, gapless gets a pump of its own")
    func noPumpGetsASeparatePump() async throws {
        let engine = AudioEngine()
        try await engine.load(self.fixtureURL())

        let preparation = try await engine.enableGaplessNext(url: self.fixtureURL()) {}

        #expect(preparation == .separatePump)
        #expect(await engine.pendingNextPump != nil)
        #expect(await engine.pendingCrossfade == nil)
        await engine.cancelGaplessNext()
    }

    @Test("Only a separate pump fires early and can be followed by a spurious end")
    func firesWhenHeard() {
        #expect(NextTrackPreparation.crossfade.firesWhenHeard)
        #expect(NextTrackPreparation.handover.firesWhenHeard)
        #expect(!NextTrackPreparation.separatePump.firesWhenHeard)
        #expect(!NextTrackPreparation.cancelled.firesWhenHeard)
    }
}

private extension AudioEngine {
    /// Test seam: a pump in place, as `play` leaves it, without playing.
    func installPumpForHandoverTest(_ pump: BufferPump) {
        self.pump = pump
    }
}
