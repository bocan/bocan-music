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
        // Let the run loop fill the window against the idle (non-playing) node.
        try await Task.sleep(for: .milliseconds(200))
        let scheduled = await pump.scheduledBufferCount
        await pump.stop()

        #expect(
            scheduled == 4,
            "in-flight window should cap at 4 buffers (~0.8 s), was \(scheduled)"
        )
    }
}
