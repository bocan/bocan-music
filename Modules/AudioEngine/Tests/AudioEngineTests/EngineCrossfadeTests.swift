@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - EngineCrossfadeTests

/// The engine's side of a crossfade (ADR-095, slice 2b): when it falls back
/// to gapless, and what a transition does to its state. None of these play
/// audio, so they need no output device; the audio itself is proved by
/// `CrossfadeRenderTests` and `BufferPumpOverlapTests`.
@Suite("AudioEngine - crossfade arming and transition")
struct EngineCrossfadeTests {
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

    @Test("With nothing playing, a crossfade falls back to the gapless preload")
    func fallsBackWithoutAPump() async throws {
        let engine = AudioEngine()
        let url = try self.fixtureURL()
        try await engine.load(url)

        let armed = try await engine.enableCrossfadeNext(url: url, overlapSeconds: 5) {}

        #expect(!armed)
        #expect(await engine.pendingNextPump != nil)
        #expect(await engine.pendingCrossfade == nil)
        await engine.cancelGaplessNext()
        #expect(await engine.pendingNextPump == nil)
    }

    @Test("A transition from an earlier arm is ignored")
    func staleTransitionIgnored() async throws {
        let engine = AudioEngine()
        try await engine.load(self.fixtureURL())
        let flag = Flag()
        let incoming = try ScriptedDecoder(format: PCMBuffers.stereo(), frames: 44100 * 7)
        await engine.installPendingCrossfade(decoder: incoming) { flag.fired = true }

        await engine.handleCrossfadeTransition(token: UUID(), firedBy: "none")

        #expect(!flag.fired)
        #expect(await engine.pendingCrossfade != nil)
        #expect(await abs(engine.duration - 1) < 0.01)
    }

    @Test("A heard transition moves the engine to the incoming track")
    func transitionMovesToIncoming() async throws {
        let engine = AudioEngine()
        try await engine.load(self.fixtureURL())
        let flag = Flag()
        let incoming = try ScriptedDecoder(format: PCMBuffers.stereo(), frames: 44100 * 7)
        await engine.installPendingCrossfade(decoder: incoming) { flag.fired = true }

        await engine.settleCrossfade(heard: true, reason: "test")

        #expect(flag.fired)
        #expect(await engine.pendingCrossfade == nil)
        #expect(await engine.decoder === incoming)
        #expect(await engine.duration == 7)
        #expect(await engine.currentTime == 0)
        #expect(incoming.closeCalls == 0, "the incoming decoder is the engine's now")
    }

    @Test("An unheard crossfade is dropped and its decoder closed")
    func unheardIsDropped() async throws {
        let engine = AudioEngine()
        try await engine.load(self.fixtureURL())
        let flag = Flag()
        let incoming = try ScriptedDecoder(format: PCMBuffers.stereo(), frames: 44100 * 7)
        await engine.installPendingCrossfade(decoder: incoming) { flag.fired = true }

        await engine.settleCrossfade(heard: false, reason: "test")

        #expect(!flag.fired)
        #expect(await engine.pendingCrossfade == nil)
        #expect(incoming.closeCalls == 1)
        #expect(await abs(engine.duration - 1) < 0.01)
    }
}

private extension AudioEngine {
    /// Test seam: the state `enableCrossfadeNext` leaves once the pump has
    /// armed, without a pump.
    func installPendingCrossfade(decoder: any Decoder, transition: @Sendable @escaping () -> Void) {
        self.pendingCrossfade = PendingCrossfade(
            token: UUID(), decoder: decoder, duration: decoder.duration, transition: transition
        )
    }
}
