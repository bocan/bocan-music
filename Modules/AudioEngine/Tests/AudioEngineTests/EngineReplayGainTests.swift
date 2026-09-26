@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - EngineReplayGainTests

/// The engine's side of ReplayGain (#573): it keeps each track's facts
/// beside its decoder, resolves them with the Settings mode and pre-amp, and
/// pushes a settings change to every track it holds. None of these play
/// audio; the samples themselves are proved by `ReplayGainPumpTests`.
@Suite("AudioEngine - ReplayGain per track (#573)")
struct EngineReplayGainTests {
    /// -6 dB track gain, -9 dB album gain, peaks low enough that the
    /// clipping guard never moves them.
    private static let facts = TrackGainInfo(
        trackGainDB: -6, trackPeakLinear: 0.5, albumGainDB: -9, albumPeakLinear: 0.5
    )

    private func fixtureURL() throws -> URL {
        let url = Bundle.module.url(
            forResource: "sine-1s-44100-16-stereo.wav", withExtension: nil, subdirectory: "Fixtures"
        )
        return try #require(url)
    }

    private static func state(_ mode: ReplayGainMode, preAmpDB: Double = 0) -> DSPState {
        var state = DSPState()
        state.replayGainMode = mode
        state.preAmpDB = preAmpDB
        return state
    }

    private static func db(_ linear: Float) -> Double {
        20 * log10(Double(linear))
    }

    @Test("A load keeps the track's ReplayGain facts; a plain load has none")
    func loadKeepsFacts() async throws {
        let engine = AudioEngine()
        let track = TrackReplayGain(values: Self.facts)
        try await engine.load(self.fixtureURL(), replayGain: track)
        #expect(await engine.currentReplayGain == track)

        try await engine.load(self.fixtureURL())
        #expect(await engine.currentReplayGain == nil)
    }

    @Test("The gain follows the mode and pre-amp from the DSP state")
    func gainFollowsSettings() async {
        let engine = AudioEngine()
        let inAlbum = TrackReplayGain(values: Self.facts, isInAlbumContext: true)

        // The default is track gain with no pre-amp, as in DSPState.
        #expect(await abs(Self.db(engine.replayGainLinear(for: inAlbum)) - -6) < 0.001)

        await engine.applyDSPState(Self.state(.album, preAmpDB: 2))
        #expect(await abs(Self.db(engine.replayGainLinear(for: inAlbum)) - -7) < 0.001)

        await engine.applyDSPState(Self.state(.auto))
        #expect(await abs(Self.db(engine.replayGainLinear(for: inAlbum)) - -9) < 0.001)

        await engine.applyDSPState(Self.state(.off, preAmpDB: 2))
        #expect(await engine.replayGainLinear(for: inAlbum) == 1)
        #expect(await engine.replayGainLinear(for: nil) == 1)
    }

    @Test("A settings change reaches the playing track and the incoming one of a crossfade")
    func settingsChangeReachesThePump() async throws {
        let engine = AudioEngine()
        let current = TrackReplayGain(values: Self.facts)
        try await engine.load(self.fixtureURL(), replayGain: current)
        let decoder = try #require(await engine.decoder)
        let pump = try await BufferPump(
            decoder: decoder,
            playerNode: engine.graph.playerNode,
            outputFormat: PCMBuffers.stereo(),
            gain: engine.replayGainLinear(for: current)
        )
        await engine.installPumpForReplayGainTest(pump)

        let incoming = try ScriptedDecoder(format: PCMBuffers.stereo(), frames: 44100 * 7)
        let next = TrackReplayGain(values: TrackGainInfo(trackGainDB: 3, trackPeakLinear: 0.1))
        _ = try await pump.armOverlap(decoder: incoming, lengthSeconds: 1, gain: engine.replayGainLinear(for: next)) {}
        await engine.installPendingCrossfadeForReplayGainTest(decoder: incoming, replayGain: next)
        #expect(await abs(Self.db(pump.current.gain) - -6) < 0.001)
        #expect(await abs(Self.db(pump.overlap?.incoming.gain ?? 0) - 3) < 0.001)

        await engine.applyDSPState(Self.state(.track, preAmpDB: -2))

        #expect(await abs(Self.db(pump.current.gain) - -8) < 0.001)
        #expect(await abs(Self.db(pump.overlap?.incoming.gain ?? 0) - 1) < 0.001)

        await engine.applyDSPState(Self.state(.off))

        #expect(await pump.current.gain == 1)
        #expect(await pump.overlap?.incoming.gain == 1)
        await pump.stop()
    }

    @Test("A gapless preload is built at its own gain, and a settings change reaches it")
    func gaplessPreloadHasItsGain() async throws {
        let engine = AudioEngine()
        try await engine.load(self.fixtureURL())
        let next = TrackReplayGain(values: Self.facts)

        try await engine.enableGaplessNext(url: self.fixtureURL(), replayGain: next) {}

        #expect(await engine.pendingNextReplayGain == next)
        let pump = try #require(await engine.pendingNextPump)
        #expect(await abs(Self.db(pump.current.gain) - -6) < 0.001)

        await engine.applyDSPState(Self.state(.track, preAmpDB: 1))
        #expect(await abs(Self.db(pump.current.gain) - -5) < 0.001)

        await engine.cancelGaplessNext()
        #expect(await engine.pendingNextReplayGain == nil)
    }

    @Test("A heard crossfade hands the incoming track's facts to the engine")
    func crossfadeTransitionMovesFacts() async throws {
        let engine = AudioEngine()
        try await engine.load(self.fixtureURL(), replayGain: TrackReplayGain(values: Self.facts))
        let incoming = try ScriptedDecoder(format: PCMBuffers.stereo(), frames: 44100 * 7)
        let next = TrackReplayGain(values: TrackGainInfo(trackGainDB: -2))
        await engine.installPendingCrossfadeForReplayGainTest(decoder: incoming, replayGain: next)

        await engine.settleCrossfade(heard: true, reason: "test")

        #expect(await engine.currentReplayGain == next)
    }
}

private extension AudioEngine {
    /// Test seam: a pump in place, as `play` leaves it, without playing.
    func installPumpForReplayGainTest(_ pump: BufferPump) {
        self.pump = pump
    }

    /// Test seam: the state `enableCrossfadeNext` leaves once the pump has armed.
    func installPendingCrossfadeForReplayGainTest(decoder: any Decoder, replayGain: TrackReplayGain) {
        self.pendingCrossfade = PendingCrossfade(
            token: UUID(), decoder: decoder, duration: decoder.duration, replayGain: replayGain
        ) {}
    }
}
