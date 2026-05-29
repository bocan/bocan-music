@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - Helpers

/// Returns `true` when an audio output device is available (needed for engine.start()).
private func audioOutputAvailable() -> Bool {
    DeviceRouter.defaultOutputDevice() != nil
}

// MARK: - RetainCycleTests

/// Regression coverage for issue #261 — retain cycles that kept the engine and
/// its pump alive across track loads.
@Suite("AudioEngine retain cycles")
struct RetainCycleTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "Missing fixture: \(name)")
    }

    /// The completion handler passed to `AVAudioPlayerNode.scheduleBuffer` must
    /// not strongly retain the pump. The node owns those handlers until each
    /// buffer is played back (or the node is reset); with a strong capture, a
    /// logically-stopped pump stays alive for the lifetime of the node. After
    /// `stop()` and dropping our reference, the pump must deallocate even while
    /// the node still owns the in-flight completion handlers.
    @Test("BufferPump does not leak via the scheduleBuffer completion handler")
    func pumpDeallocatesWithInFlightCallbacks() async throws {
        let graph = EngineGraph()
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let outputFormat = try #require(
            StereoLayout.format(sampleRate: 44100), "Could not build output format"
        )

        weak var weakPump: BufferPump?
        do {
            let decoder = try DecoderFactory.make(for: url)
            let pump = try BufferPump(
                decoder: decoder,
                playerNode: graph.playerNode,
                outputFormat: outputFormat
            )
            weakPump = pump
            await pump.start {}
            // Let the run loop fill its in-flight window, registering completion
            // handlers on the (idle) player node.
            try await Task.sleep(for: .milliseconds(150))
            let scheduled = await pump.scheduledBufferCount
            #expect(
                scheduled > 0,
                "precondition: pump should have scheduled buffers, registering handlers on the node"
            )
            await pump.stop()
            await decoder.close()
        }
        // The node still owns the in-flight completion handlers; the pump must
        // nonetheless be gone now that nothing else references it.
        #expect(weakPump == nil, "BufferPump leaked — scheduleBuffer completion handler retains it")
    }

    /// `play()` installs an `onEnded` closure into the pump. If that closure
    /// captures the engine strongly, engine → pump → onEnded → engine forms a
    /// cycle that never releases while a track is loaded. After the playing
    /// engine finishes the (short) fixture and the owner drops its reference,
    /// the engine must deallocate without an explicit `stop()`/`load()` (which
    /// would otherwise nil the pump and mask the cycle).
    @Test(
        "playing engine deallocates once the owner releases it",
        .enabled(if: audioOutputAvailable())
    )
    func engineDeallocatesAfterPlay() async throws {
        weak var weakEngine: AudioEngine?
        do {
            let engine = AudioEngine()
            weakEngine = engine
            let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
            try await engine.load(url)
            try await engine.play()
            try await Task.sleep(for: .milliseconds(200))
            // Intentionally no stop()/load(): exercise the play()-installed
            // onEnded retain path directly.
        }
        // Allow the 1 s fixture to reach EOF and in-flight tasks to drain.
        try await Task.sleep(for: .seconds(2))
        #expect(weakEngine == nil, "AudioEngine leaked — pump.onEnded retain cycle")
    }
}
