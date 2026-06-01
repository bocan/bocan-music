@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - ContinuousDecoder

/// A decoder that always fills the buffer and never reports end-of-stream, so
/// the pump's in-flight window is bounded purely by `windowSize` rather than by
/// the source running out of data.
private final class ContinuousDecoder: Decoder, @unchecked Sendable {
    let sourceFormat: AVAudioFormat
    let duration: TimeInterval = 3600
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

    func read(into buffer: AVAudioPCMBuffer) async throws -> AVAudioFrameCount {
        buffer.frameLength = buffer.frameCapacity // zero-filled silence is fine
        return buffer.frameCapacity
    }

    func seek(to _: TimeInterval) async throws {}
    func close() async {}
}

// MARK: - BufferPumpWindowTests

@Suite("BufferPump in-flight window")
struct BufferPumpWindowTests {
    /// Regression for #277: the pre-scheduled window must stay at 4 buffers
    /// (~0.8 s). The whole window is torn down and refilled on every seek, so an
    /// oversized window directly inflates seek latency against the < 50 ms
    /// baseline. The player node is never started, so no `dataPlayedBack`
    /// callbacks fire to free slots — the pump fills exactly `windowSize`
    /// buffers and then blocks, letting us read the window size back.
    @Test("the pre-scheduled window caps at four buffers")
    func windowCapsAtFour() async throws {
        let graph = EngineGraph()
        let format = try #require(StereoLayout.format(sampleRate: 44100))
        let pump = try BufferPump(
            decoder: ContinuousDecoder(format: format),
            playerNode: graph.playerNode,
            outputFormat: format
        )

        await pump.start {}
        // Wait for the window to fill to its cap and settle, rather than sleeping
        // a fixed interval. The fixed sleep raced the async fill loop under CI
        // load and read a half-filled window (#277 regression seen as
        // scheduled == 1 with a 200 ms sleep).
        let scheduled = try await Self.awaitWindowSettled(pump, target: 4)
        await pump.stop()

        #expect(
            scheduled == 4,
            "in-flight window should cap at 4 buffers (~0.8 s), was \(scheduled)"
        )
    }

    /// Waits for the pump's in-flight window to reach `target`, then settles
    /// briefly before reporting the count.
    ///
    /// Waiting for the real cap (instead of a fixed `Task.sleep`) removes the
    /// race that made this flaky: under load the fill loop can schedule just one
    /// buffer before the read. The trailing settle lets an *oversized* window —
    /// which would keep climbing past the cap — still fail the caller's
    /// `== target` check rather than passing on a transient mid-fill reading.
    private static func awaitWindowSettled(_ pump: BufferPump, target: Int) async throws -> Int {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if await pump.scheduledBufferCount >= target { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100)) // let any overshoot manifest
        return await pump.scheduledBufferCount
    }
}
