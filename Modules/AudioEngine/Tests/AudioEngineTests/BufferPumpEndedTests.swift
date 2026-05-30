@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - ImmediateEOFDecoder

/// A decoder that reports end-of-stream on its first read, so the pump reaches
/// its EOF branch immediately without any audio hardware.
private final class ImmediateEOFDecoder: Decoder, @unchecked Sendable {
    let sourceFormat: AVAudioFormat
    let duration: TimeInterval = 0
    var position: TimeInterval {
        get async { 0 }
    }

    init(format: AVAudioFormat) {
        self.sourceFormat = format
    }

    init(url _: URL) throws {
        guard let fmt = StereoLayout.format(sampleRate: 44100) else {
            throw AudioEngineError.outputDeviceUnavailable
        }
        self.sourceFormat = fmt
    }

    func read(into _: AVAudioPCMBuffer) async throws -> AVAudioFrameCount {
        0
    }

    func seek(to _: TimeInterval) async throws {}
    func close() async {}
}

// MARK: - BufferPumpEndedTests

@Suite("BufferPump end-of-stream")
struct BufferPumpEndedTests {
    /// Captures whether the callback ran on the main thread. `@unchecked
    /// Sendable`: written once by the `onEnded` closure, read after the pump has
    /// stopped, so there is no real race.
    private final class Sink: @unchecked Sendable {
        var observedMainThread = true
        var fired = false
    }

    /// Regression for issue #262: `onEnded` was dispatched through an extra
    /// `Task { @MainActor in … }` hop before the closure (which already hops to
    /// the engine actor itself) ran. The intermediate hop bought nothing and
    /// could drop the handoff if the engine deallocated between the two hops.
    /// The callback is now invoked directly on the pump's executor — so it must
    /// fire at EOF, and must NOT be marshalled onto the main thread.
    @Test("onEnded fires at EOF directly on the pump executor (no @MainActor hop)")
    func onEndedFiresDirectlyAtEOF() async throws {
        let graph = EngineGraph()
        let format = try #require(StereoLayout.format(sampleRate: 44100))
        let pump = try BufferPump(
            decoder: ImmediateEOFDecoder(format: format),
            playerNode: graph.playerNode,
            outputFormat: format
        )

        let sink = Sink()
        await confirmation("onEnded fires at EOF") { confirmed in
            await pump.start {
                sink.observedMainThread = Thread.isMainThread
                sink.fired = true
                confirmed()
            }
            // The decoder returns EOF on the first read, so onEnded fires almost
            // immediately; this is a generous ceiling.
            try? await Task.sleep(for: .milliseconds(200))
        }
        await pump.stop()

        #expect(sink.fired, "onEnded should fire when the decoder hits EOF")
        #expect(
            sink.observedMainThread == false,
            "onEnded should be invoked directly on the pump executor, not hopped through @MainActor"
        )
    }
}
