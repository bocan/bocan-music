@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - DeviceChangeRearmTests

/// A device change rebuilds the pump. An unheard crossfade or gapless
/// hand-over used to be dropped with it, so the next track started with a
/// normal load and a gap. Now its decoder stays open through the pump's stop,
/// and the engine arms the same boundary again on the new pump. The playing
/// track resumes where the listener was, not up to ~0.8 s further on at the
/// decoder's read position.
@Suite("Device change - playback survives the pump rebuild")
struct DeviceChangeRearmTests {
    private final class Flag: @unchecked Sendable {
        // @unchecked: set once by the transition closure, read after it ran.
        var fired = false
    }

    private func fixtureURL() throws -> URL {
        let url = Bundle.module.url(
            forResource: "sine-1s-44100-16-stereo.wav", withExtension: nil, subdirectory: "Fixtures"
        )
        return try #require(url)
    }

    // MARK: - Pump

    @Test("Stopping keeps the named incoming decoder open, and still closes one it was not told to keep")
    func stopKeepsNamedDecoder() async throws {
        let harness = try OfflineRenderHarness()
        let outgoing = ScriptedDecoder(format: harness.format, frames: 132_300)
        let kept = ScriptedDecoder(format: harness.format, frames: 132_300)
        let pump = try harness.makePump(outgoing)
        _ = try await pump.armOverlap(decoder: kept, lengthSeconds: 0) {}
        await pump.stop(keepingOpen: kept)
        #expect(kept.closeCalls == 0)
        #expect(await pump.overlap == nil)

        let dropped = ScriptedDecoder(format: harness.format, frames: 132_300)
        let other = try harness.makePump(ScriptedDecoder(format: harness.format, frames: 132_300))
        _ = try await other.armOverlap(decoder: dropped, lengthSeconds: 0) {}
        await other.stop(keepingOpen: kept)
        #expect(dropped.closeCalls == 1)
    }

    @Test("A hand-over already scheduled from the incoming track is kept open too, and the pump goes back to the outgoing one")
    func stopAfterHandoverKeepsIncoming() async throws {
        let harness = try OfflineRenderHarness()
        let outgoing = ScriptedDecoder(format: harness.format, frames: 44100, signal: .constant(0.5))
        let incoming = ScriptedDecoder(format: harness.format, frames: 132_300, signal: .constant(0.25))
        let pump = try harness.makePump(outgoing)
        let clock = harness.clock
        _ = try await pump.armOverlap(decoder: incoming, lengthSeconds: 0) { clock.recordTransition() }
        await pump.start {}
        // Past the outgoing track's end in scheduling, before it is heard:
        // render to about a buffer short of it so the window reaches past.
        try await harness.render(44100 - 10000, from: pump)
        try await harness.waitForScheduled(44100 + 1, pump: pump)
        #expect(harness.clock.transitions.isEmpty)

        let heard = await pump.stop(keepingOpen: incoming)

        #expect(!heard)
        #expect(incoming.closeCalls == 0)
        #expect(await pump.current.decoder === outgoing)
    }

    // MARK: - Engine

    @Test("A carried hand-over is armed again on the new pump, with its decoder rewound")
    func rearmsHandover() async throws {
        let (engine, pump) = try await self.playingEngine()
        let incoming = try ScriptedDecoder(format: PCMBuffers.stereo(), frames: 44100 * 7)
        _ = try await incoming.read(into: PCMBuffers.empty(capacity: 4410, format: PCMBuffers.stereo()))
        let flag = Flag()
        let carried = Self.carried(incoming, lengthSeconds: 0) { flag.fired = true }

        await engine.rearm(carried, after: engine.decoder)

        #expect(incoming.seekTargets == [0], "rewound: the old pump had read from it")
        let pending = try #require(await engine.pendingCrossfade)
        #expect(pending.decoder === incoming)
        #expect(pending.lengthSeconds == 0)
        #expect(await pump.overlap?.lengthFrames == 0)
        #expect(incoming.closeCalls == 0)

        // The transition it carries is the one the player gave at arming.
        await engine.settleCrossfade(heard: true, reason: "test")
        #expect(flag.fired)
        await pump.stop()
    }

    @Test("A carried crossfade is armed again at the same length")
    func rearmsCrossfade() async throws {
        let (engine, pump) = try await self.playingEngine()
        let incoming = try ScriptedDecoder(format: PCMBuffers.stereo(), frames: 44100 * 20)
        let carried = Self.carried(incoming, lengthSeconds: 3) {}

        await engine.rearm(carried, after: engine.decoder)

        let pending = try #require(await engine.pendingCrossfade)
        #expect(pending.decoder === incoming)
        #expect(pending.lengthSeconds == 3)
        #expect(await pump.overlap?.lengthFrames == 3 * 44100)
        await engine.cancelGaplessNext()
        await pump.stop()
    }

    @Test("A boundary that cannot be armed again is closed, so the next track loads normally")
    func failedRearmCloses() async throws {
        let engine = AudioEngine()
        try await engine.load(self.fixtureURL())
        let incoming = try ScriptedDecoder(format: PCMBuffers.stereo(), frames: 44100 * 7)
        incoming.seekError = AudioEngineError.outputDeviceUnavailable
        let carried = Self.carried(incoming, lengthSeconds: 0) {}

        await engine.rearm(carried, after: engine.decoder)

        #expect(incoming.closeCalls == 1)
        #expect(await engine.pendingCrossfade == nil)
        #expect(await engine.pendingNextPump == nil)
    }

    @Test("With no pump to take it, the boundary is closed, never given a pump of its own")
    func refusedRearmClosesWithoutSeparatePump() async throws {
        let engine = AudioEngine()
        try await engine.load(self.fixtureURL())
        let incoming = try ScriptedDecoder(format: PCMBuffers.stereo(), frames: 44100 * 7)
        let carried = Self.carried(incoming, lengthSeconds: 0) {}

        await engine.rearm(carried, after: engine.decoder)

        #expect(incoming.closeCalls == 1)
        #expect(await engine.pendingNextPump == nil, "a separate pump could outlive the track it was for")
        #expect(await engine.pendingCrossfade == nil)
    }

    @Test("A boundary whose track was replaced by a load during the device change is closed, not armed")
    func trackChangedDuringRebuildCloses() async throws {
        let (engine, pump) = try await self.playingEngine()
        let before = try #require(await engine.decoder)
        // A load (Next, a double-click) ran while the device change awaited.
        try await engine.load(self.fixtureURL())
        await engine.installPumpForRearmTest(pump)
        let incoming = try ScriptedDecoder(format: PCMBuffers.stereo(), frames: 44100 * 7)
        let flag = Flag()
        let carried = Self.carried(incoming, lengthSeconds: 0) { flag.fired = true }

        await engine.rearm(carried, after: before)

        #expect(incoming.closeCalls == 1)
        #expect(incoming.seekTargets.isEmpty, "not touched beyond closing")
        #expect(await engine.pendingCrossfade == nil)
        #expect(await engine.pendingNextPump == nil)
        #expect(!flag.fired)
        await pump.stop()
    }

    // MARK: - Position

    @Test("A device change resumes where the listener was, not at the decoder's read position")
    func deviceChangeRewindsToHeardPosition() async throws {
        let engine = AudioEngine()
        try await engine.load(self.fixtureURL())
        // The decoder has read ahead of what was heard, as a pump's window does.
        let decoder = try ScriptedDecoder(format: PCMBuffers.stereo(), frames: 44100 * 10)
        try await decoder.seek(to: 1.2)
        await engine.installForRewindTest(decoder: decoder, pausedAt: 0.4)

        await engine.handleDefaultDeviceChange()

        #expect(decoder.seekTargets == [1.2, 0.4])
        #expect(await decoder.position == 0.4)
        #expect(await engine.currentTime == 0.4)
    }

    @Test("A live stream is not rewound: it cannot seek")
    func liveStreamIsNotRewound() async throws {
        let engine = AudioEngine()
        let decoder = try ScriptedDecoder(format: PCMBuffers.stereo(), frames: nil)
        let stream = try #require(URL(string: "https://example.invalid/live"))
        await engine.installForRewindTest(decoder: decoder, pausedAt: 5, url: stream, duration: 0)

        await engine.rewindForRebuild(to: 5, on: decoder)

        #expect(decoder.seekTargets.isEmpty)
    }

    @Test("A rewind for another track's decoder does nothing")
    func otherTrackIsNotRewound() async throws {
        let engine = AudioEngine()
        let current = try ScriptedDecoder(format: PCMBuffers.stereo(), frames: 44100 * 10)
        let before = try ScriptedDecoder(format: PCMBuffers.stereo(), frames: 44100 * 10)
        await engine.installForRewindTest(decoder: current, pausedAt: 2)

        await engine.rewindForRebuild(to: 2, on: before)

        #expect(current.seekTargets.isEmpty)
        #expect(before.seekTargets.isEmpty)
    }

    // MARK: - Helpers

    /// An engine with the fixture loaded and a pump in place, as `play` leaves it.
    private func playingEngine() async throws -> (AudioEngine, BufferPump) {
        let engine = AudioEngine()
        try await engine.load(self.fixtureURL())
        let decoder = try #require(await engine.decoder)
        let pump = try await BufferPump(
            decoder: decoder,
            playerNode: engine.graph.playerNode,
            outputFormat: PCMBuffers.stereo()
        )
        await engine.installPumpForRearmTest(pump)
        return (engine, pump)
    }

    private static func carried(
        _ decoder: any Decoder,
        lengthSeconds: TimeInterval,
        transition: @Sendable @escaping () -> Void
    ) -> PendingCrossfade {
        PendingCrossfade(
            token: UUID(),
            decoder: decoder,
            duration: decoder.duration,
            url: URL(fileURLWithPath: "/tmp/next.wav"),
            lengthSeconds: lengthSeconds,
            replayGain: nil,
            transition: transition
        )
    }
}

private extension AudioEngine {
    /// Test seam: a pump in place, as `play` leaves it, without playing.
    func installPumpForRearmTest(_ pump: BufferPump) {
        self.pump = pump
    }

    /// Test seam: `decoder` loaded and paused at `position`, as `pause`
    /// leaves the engine, optionally as a stream of `url`.
    func installForRewindTest(
        decoder: any Decoder,
        pausedAt position: TimeInterval,
        url: URL? = nil,
        duration: TimeInterval = 10
    ) {
        self.decoder = decoder
        self.currentURL = url
        self._duration = duration
        self._currentTime = position
        self.emit(.paused)
    }
}
