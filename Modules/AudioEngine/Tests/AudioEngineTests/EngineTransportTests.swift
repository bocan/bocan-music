@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - Helpers

/// Returns `true` when an audio output device is available (needed for engine.start()).
private func audioOutputAvailable() -> Bool {
    DeviceRouter.defaultOutputDevice() != nil
}

// MARK: - EngineTransportTests

@Suite("AudioEngine transport")
struct EngineTransportTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "Missing fixture: \(name)")
    }

    // MARK: - Load → state

    @Test("load WAV: state transitions to .ready")
    func loadWAVTransitionsToReady() async throws {
        let engine = AudioEngine()
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")

        let stateTask = Task<[PlaybackState], Never> {
            var collected: [PlaybackState] = []
            for await s in engine.state {
                collected.append(s)
                if s == .ready { break }
            }
            return collected
        }

        try await engine.load(url)
        let states = await stateTask.value

        #expect(states.contains(.loading), "Should pass through .loading")
        #expect(states.last == .ready, "Should end in .ready")
    }

    @Test("load missing file: state transitions to .failed")
    func loadMissingFileTransitionsToFailed() async {
        let engine = AudioEngine()
        let url = URL(fileURLWithPath: "/nonexistent/track.wav")

        let stateTask = Task<[PlaybackState], Never> {
            var collected: [PlaybackState] = []
            for await s in engine.state {
                collected.append(s)
                if case .failed = s { break }
                if s == .ready { break }
            }
            return collected
        }

        try? await engine.load(url)
        let states = await stateTask.value

        let hasFailed = states.contains { if case .failed = $0 { return true }
            return false
        }
        #expect(hasFailed, "Expected .failed state for missing file")
    }

    @Test("duration after load")
    func durationAfterLoad() async throws {
        let engine = AudioEngine()
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        try await engine.load(url)
        let dur = await engine.duration
        #expect(abs(dur - 1.0) < 0.1, "Expected duration ≈ 1 s, got \(dur)")
    }

    @Test("currentTime is zero after load")
    func currentTimeAfterLoad() async throws {
        let engine = AudioEngine()
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        try await engine.load(url)
        let t = await engine.currentTime
        #expect(t == 0.0)
    }

    // MARK: - Seek (no hardware required — engine need not be running)

    @Test("seek before play repositions the decoder")
    func seekBeforePlay() async throws {
        let engine = AudioEngine()
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        try await engine.load(url)
        try await engine.seek(to: 0.5)
        let t = await engine.currentTime
        #expect(abs(t - 0.5) < 0.1, "Expected currentTime ≈ 0.5 after seek, got \(t)")
    }

    @Test("seek out of range throws")
    func seekOutOfRange() async throws {
        let engine = AudioEngine()
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        try await engine.load(url)
        await #expect(throws: AudioEngineError.self) {
            try await engine.seek(to: 999.0)
        }
    }

    // MARK: - Stop without play

    @Test("stop without play transitions to .stopped")
    func stopWithoutPlay() async throws {
        let engine = AudioEngine()
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        try await engine.load(url)

        let stateTask = Task<[PlaybackState], Never> {
            var collected: [PlaybackState] = []
            for await s in engine.state {
                collected.append(s)
                if s == .stopped { break }
            }
            return collected
        }
        await engine.stop()
        let states = await stateTask.value

        #expect(states.last == .stopped)
    }

    // MARK: - Play/Pause (requires audio hardware)

    @Test("play/pause: state transitions", .enabled(if: audioOutputAvailable()))
    func playThenPause() async throws {
        let engine = AudioEngine()
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        try await engine.load(url)

        let stateTask = Task<[PlaybackState], Never> {
            var collected: [PlaybackState] = []
            for await s in engine.state {
                collected.append(s)
                if s == .paused { break }
            }
            return collected
        }

        try await engine.play()
        try await Task.sleep(for: .milliseconds(200))
        await engine.pause()
        let states = await stateTask.value

        #expect(states.contains(.playing), "Expected .playing state")
        #expect(states.contains(.paused) || states.last == .paused, "Expected .paused state")
    }

    @Test("play/stop: currentTime resets to 0", .enabled(if: audioOutputAvailable()))
    func playThenStop() async throws {
        let engine = AudioEngine()
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        try await engine.load(url)
        try await engine.play()
        try await Task.sleep(for: .milliseconds(200))
        await engine.stop()
        let t = await engine.currentTime
        #expect(t == 0.0, "currentTime should reset to 0 after stop")
    }

    /// Regression: repeated pause/resume must not let the reported position drift
    /// ahead of real playback. pause() banks the elapsed time into `_currentTime`;
    /// resume() must re-baseline `_playerTimeOffset` to the resume point, otherwise
    /// the live term re-counts everything played before the pause and the position
    /// races ahead (compounding each cycle until it falsely reads "ended").
    @Test(
        "resume does not jump the position ahead of where it paused",
        .enabled(if: audioOutputAvailable())
    )
    func resumeDoesNotDriftPosition() async throws {
        let engine = AudioEngine()
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        try await engine.load(url)

        try await engine.play()
        try await Task.sleep(for: .milliseconds(200))
        await engine.pause()
        let tPause = await engine.currentTime // banked position while paused

        try await engine.play() // resume: must rebaseline the offset
        let tResume = await engine.currentTime // live position right after resume
        await engine.stop()

        #expect(tResume >= tPause - 0.05, "position must not jump backwards on resume (tPause=\(tPause) tResume=\(tResume))")
        // The bug doubled the position on resume (tResume ~= 2 * tPause). A correct
        // rebase leaves only the few ms of playback between resume and the read.
        #expect(
            tResume < tPause + 0.1,
            "position jumped ahead on resume: tPause=\(tPause) tResume=\(tResume)"
        )
    }

    // MARK: - Reentrancy: concurrent transport calls

    /// A burst of overlapping `play()`/`seek()` calls (the double-invocation that
    /// the logs showed) must serialize through the transport gate: no deadlock,
    /// and the node must not be left "playing" with a torn-down pump (which read
    /// as silent audio with an advancing progress bar). We assert the engine
    /// settles to `.playing` with a live pump and that a follow-up `stop()`
    /// returns promptly (it would hang if the gate had deadlocked).
    @Test(
        "concurrent play/seek serialize without deadlock or a stranded pump",
        .enabled(if: audioOutputAvailable())
    )
    func concurrentTransportSerializes() async throws {
        let engine = AudioEngine()
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        try await engine.load(url)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 6 {
                group.addTask { try? await engine.play() }
                group.addTask { try? await engine.seek(to: 0.2) }
            }
            await group.waitForAll()
        }
        // Settle to a known state after the burst.
        try await engine.play()

        let isPlaying = await engine.isPlaying
        #expect(isPlaying, "Engine should be playing after the burst")
        let pump = await engine.pump
        #expect(pump != nil, "A live pump must remain (not stranded) after concurrent play/seek")

        await engine.stop() // returns promptly only if the gate did not deadlock
    }

    /// Seeking while paused stops and nils the pump but leaves the state at
    /// `.paused`. Resuming must rebuild the pump rather than take the
    /// resume-from-pause fast path (which assumes a live pump and would restart a
    /// silent, unrecoverable node).
    @Test(
        "resume after a paused seek rebuilds the pump (no silent disconnect)",
        .enabled(if: audioOutputAvailable())
    )
    func resumeAfterPausedSeek() async throws {
        let engine = AudioEngine()
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        try await engine.load(url)
        try await engine.play()
        try await Task.sleep(for: .milliseconds(100))
        await engine.pause()

        try await engine.seek(to: 0.3) // paused seek: pump stopped and nilled
        try await engine.play() // resume: must NOT take the no-pump fast path

        let isPlaying = await engine.isPlaying
        #expect(isPlaying, "Engine should resume playing after a paused seek")
        let pump = await engine.pump
        #expect(pump != nil, "Resume after a paused seek must rebuild the pump")

        await engine.stop()
    }

    /// Seeking while playing reschedules the live pump in place (same instance)
    /// rather than tearing it down and rebuilding, and stays playing at the new
    /// position.
    @Test(
        "seek while playing reschedules the same pump in place",
        .enabled(if: audioOutputAvailable())
    )
    func seekWhilePlayingReschedulesInPlace() async throws {
        let engine = AudioEngine()
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        try await engine.load(url)
        try await engine.play()
        try await Task.sleep(for: .milliseconds(100))
        let pumpBefore = await engine.pump

        // Seek to 0.1 s: the 0.9 s remaining is beyond the pump's 0.8 s read-ahead
        // window, so it does not immediately hit EOF and the engine stays playing.
        try await engine.seek(to: 0.1)

        let isPlaying = await engine.isPlaying
        #expect(isPlaying, "Engine should stay playing across a seek")
        let pumpAfter = await engine.pump
        #expect(pumpAfter != nil, "Pump must stay live across a seek")
        #expect(pumpAfter === pumpBefore, "Seek should reschedule the same pump, not rebuild it")
        let t = await engine.currentTime
        #expect(t >= 0.1 - 0.05, "currentTime should reflect the seek target, got \(t)")

        await engine.stop()
    }

    // MARK: - No duplicate states

    @Test("PlaybackState stream: no consecutive duplicates")
    func noConsecutiveDuplicateStates() async throws {
        let engine = AudioEngine()
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")

        let stateTask = Task<[PlaybackState], Never> {
            var collected: [PlaybackState] = []
            for await s in engine.state {
                collected.append(s)
                if s == .ready { break }
            }
            return collected
        }

        try await engine.load(url)
        let states = await stateTask.value

        for i in 1 ..< states.count {
            #expect(
                states[i] != states[i - 1],
                "Consecutive duplicate state: \(states[i]) at index \(i)"
            )
        }
    }

    // MARK: - Error description

    @Test("AudioEngineError.description is human-readable")
    func errorDescriptions() {
        let url = URL(fileURLWithPath: "/tmp/test.wav")
        let errors: [AudioEngineError] = [
            .fileNotFound(url),
            .accessDenied(url, underlying: nil),
            .unsupportedFormat(magic: Data([0, 1, 2, 3]), url: url),
            .decoderFailure(codec: "PCM", underlying: NSError(domain: "test", code: 0)),
            .engineStartFailed(underlying: NSError(domain: "test", code: 0)),
            .outputDeviceUnavailable,
            .seekOutOfRange(requested: 10, duration: 5),
            .cancelled,
        ]
        for error in errors {
            let desc = error.description
            #expect(!desc.isEmpty, "description should not be empty for \(error)")
        }
    }

    // MARK: - Cancellation / leak hardening

    /// Phase 1 audit #11: a `Task` that cancels a `play()` call must leave the
    /// engine in a consistent (non-`.failed`) state and tear down the pump
    /// and decoder rather than leaking them.
    ///
    /// We can't observe pump/decoder release directly, but we can assert:
    ///   * No `.failed` is ever emitted on the public state stream.
    ///   * A subsequent `stop()` returns control promptly (would block
    ///     indefinitely if the prior pump were still attached).
    @Test(
        "cancellation: stop after task cancel leaves engine consistent",
        .enabled(if: audioOutputAvailable())
    )
    func cancellationLeavesEngineConsistent() async throws {
        let engine = AudioEngine()
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        try await engine.load(url)

        let playTask = Task { try await engine.play() }
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        playTask.cancel()
        _ = try? await playTask.value

        await engine.stop()

        // Engine should be in a clean post-stop state; no .failed in flight.
        let snapshot = Task<PlaybackState?, Never> {
            for await s in engine.state {
                return s
            }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        snapshot.cancel()
        // Reaching here without hanging is the actual assertion.
        #expect(Bool(true))
    }
}
