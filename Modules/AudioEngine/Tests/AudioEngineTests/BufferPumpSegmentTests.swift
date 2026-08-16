@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - CountingDecoder

/// A never-ending decoder that fills every buffer and counts its reads, so a
/// test can measure exactly how much source audio the pump consumed before a
/// CUE segment boundary stopped it.
private final class CountingDecoder: Decoder, @unchecked Sendable {
    let sourceFormat: AVAudioFormat
    let duration: TimeInterval = 3600
    private(set) var readCalls = 0
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
        self.readCalls += 1
        buffer.frameLength = buffer.frameCapacity // zero-filled silence is fine
        return buffer.frameCapacity
    }

    func seek(to _: TimeInterval) async throws {}
    func close() async {}
}

// MARK: - BufferPumpSegmentTests

@Suite("BufferPump CUE segment boundary")
struct BufferPumpSegmentTests {
    /// Regression: `maxFrames` was computed from the OUTPUT sample rate, but
    /// the feed loop compares it against decoder-native `framesRead` (the
    /// limit check runs before resampling). With a 44.1k source on a 48k
    /// output, a segment's budget was 48000/44100 ≈ 8.8% too large, so a CUE
    /// track audibly played the next track's opening before ending.
    ///
    /// Arithmetic: source 44.1k, buffers of 0.2 s = 8820 source frames, and a
    /// 0.6 s segment = 26460 source frames = exactly 3 reads. The buggy
    /// output-rate budget (0.6 × 48000 = 28800) needs a 4th read to cross the
    /// limit. The player node is never started, so nothing renders; 4 fits the
    /// in-flight window either way (no deadlock, no flake).
    @Test("the segment frame budget counts decoder-native frames, not output frames")
    func segmentBudgetUsesSourceRate() async throws {
        let graph = EngineGraph()
        let source = try #require(StereoLayout.format(sampleRate: 44100))
        let output = try #require(StereoLayout.format(sampleRate: 48000))
        let decoder = CountingDecoder(format: source)
        let pump = try BufferPump(
            decoder: decoder,
            playerNode: graph.playerNode,
            outputFormat: output,
            maxDuration: 0.6
        )

        await confirmation("segment end fires") { confirmed in
            await pump.start { confirmed() }
            try? await Task.sleep(for: .milliseconds(300))
        }
        await pump.stop()

        #expect(
            decoder.readCalls == 3,
            "0.6s at 44.1k is exactly 3 reads; \(decoder.readCalls) reads means the budget was computed in the wrong rate domain"
        )
    }
}
