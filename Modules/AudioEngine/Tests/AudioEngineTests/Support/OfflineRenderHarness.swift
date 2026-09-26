@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - OfflineRenderHarness

/// Plays a `BufferPump` through a real `AVAudioPlayerNode` in offline manual
/// rendering mode and keeps what comes out (ADR-095, slice 2b).
///
/// The graph is the node alone into the main mixer, not the app's DSP chain:
/// the chain is not what these tests are about, and a flat chain would only
/// add tolerance. The pump reports buffers done with `.dataRendered`, because
/// offline rendering never reports `.dataPlayedBack` (the SDK documents that
/// type for device rendering only; checked on macOS 27).
///
/// Rendering is driven by the test, so it never runs ahead of the pump:
/// before each chunk the harness waits until the pump has scheduled past it.
/// That keeps the rendered stream exactly the concatenation of the scheduled
/// buffers, with no underrun silence.
final class OfflineRenderHarness {
    let format: AVAudioFormat
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    /// Frames rendered since the node last started from its own frame 0.
    /// Shared with the pump callbacks, which read it to timestamp events.
    let clock = RenderClock()
    /// Channel 0 of everything rendered since the last `restart`.
    private(set) var rendered: [Float] = []

    private static let chunkFrames = 1024

    init(sampleRate: Double = 44100) throws {
        self.format = try PCMBuffers.stereo(sampleRate: sampleRate)
        self.engine.attach(self.node)
        self.engine.connect(self.node, to: self.engine.mainMixerNode, format: self.format)
        try self.engine.enableManualRenderingMode(.offline, format: self.format, maximumFrameCount: 4096)
        try self.engine.start()
        self.node.play()
    }

    deinit {
        self.engine.stop()
    }

    /// A pump on this harness's node, reporting buffers done as rendered.
    func makePump(_ decoder: any Decoder) throws -> BufferPump {
        try BufferPump(
            decoder: decoder,
            playerNode: self.node,
            outputFormat: self.format,
            completionCallbackType: .dataRendered
        )
    }

    /// After `reschedule` flushed the node: play it again and start a fresh
    /// capture from its frame 0.
    func restart() {
        self.node.play()
        self.rendered = []
        self.clock.frames = 0
    }

    /// Render up to `frames` more frames. Stops early, without error, once
    /// the pump has reached its end and everything it scheduled is rendered.
    func render(_ frames: Int, from pump: BufferPump) async throws {
        let output = try PCMBuffers.empty(capacity: Self.chunkFrames, format: self.engine.manualRenderingFormat)
        var done = 0
        while done < frames {
            let want = min(Self.chunkFrames, frames - done)
            let available = try await self.waitForScheduled(self.rendered.count + want, pump: pump)
            let count = min(want, available - self.rendered.count)
            guard count > 0 else { return }
            let status = try self.engine.renderOffline(AVAudioFrameCount(count), to: output)
            try #require(status == .success, "offline render returned \(status.rawValue)")
            try self.rendered.append(contentsOf: PCMBuffers.samples(output))
            self.clock.frames = self.rendered.count
            done += count
        }
    }

    /// Render until the pump has ended and all it scheduled is out.
    func renderToEnd(from pump: BufferPump, limit: Int = 44100 * 30) async throws {
        try await self.render(limit, from: pump)
    }

    /// Waits until the pump has scheduled `target` frames since the flush, or
    /// has ended. Returns the frames scheduled.
    @discardableResult
    func waitForScheduled(_ target: Int, pump: BufferPump) async throws -> Int {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let scheduled = await Int(pump.framesScheduledSinceFlush)
            if scheduled >= target {
                return scheduled
            }
            if await pump.reachedEnd {
                // The end is signalled after the last buffer is scheduled.
                return await Int(pump.framesScheduledSinceFlush)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        await Issue.record("the pump stalled at \(pump.framesScheduledSinceFlush) frames, wanted \(target)")
        return await Int(pump.framesScheduledSinceFlush)
    }
}

// MARK: - RenderClock

/// The harness's rendered-frame count, readable from pump callbacks, plus the
/// events those callbacks record against it.
final class RenderClock: @unchecked Sendable {
    // @unchecked: every field is guarded by `lock`.
    private let lock = NSLock()
    private var renderedFrames = 0
    private var transitionFrames: [Int] = []
    private var endedCount = 0

    var frames: Int {
        get { self.lock.withLock { self.renderedFrames } }
        set { self.lock.withLock { self.renderedFrames = newValue } }
    }

    /// Rendered-frame counts at which a crossfade transition fired.
    var transitions: [Int] {
        self.lock.withLock { self.transitionFrames }
    }

    var ended: Int {
        self.lock.withLock { self.endedCount }
    }

    func recordTransition() {
        self.lock.withLock { self.transitionFrames.append(self.renderedFrames) }
    }

    func recordEnded() {
        self.lock.withLock { self.endedCount += 1 }
    }

    /// Waits until `count` transitions have fired; fails the test after 10 s.
    func waitForTransitions(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while self.transitions.count < count {
            guard ContinuousClock.now < deadline else {
                Issue.record("expected \(count) transitions, saw \(self.transitions.count)")
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

// MARK: - CrossfadeCurve

/// Expected output of a crossfade between two constant tracks, and a way to
/// compare it with what was rendered.
enum CrossfadeCurve {
    /// `outgoing * gOut(frame) + incoming * gIn(frame)` for an overlap of
    /// `length` frames, the value the mix should produce.
    static func mixed(_ outgoing: Float, _ incoming: Float, frame: Int, of length: Int) -> Float {
        let gains = CrossfadeMix.gains(atFrame: frame, of: length)
        return outgoing * gains.outgoing + incoming * gains.incoming
    }

    /// The largest `|samples[i] - expected(i - range.lowerBound)|` over `range`.
    /// Infinity when the range runs past the samples, so a short render fails.
    static func maxDeviation(_ samples: [Float], _ range: Range<Int>, expected: (Int) -> Float) -> Float {
        guard range.upperBound <= samples.count else { return .infinity }
        var worst: Float = 0
        for index in range {
            worst = max(worst, abs(samples[index] - expected(index - range.lowerBound)))
        }
        return worst
    }

    /// The largest step between neighbouring samples over `range`.
    static func maxStep(_ samples: [Float], _ range: Range<Int>) -> Float {
        guard range.lowerBound >= 0, range.upperBound <= samples.count, range.count > 1 else { return .infinity }
        var worst: Float = 0
        for index in range.dropFirst() {
            worst = max(worst, abs(samples[index] - samples[index - 1]))
        }
        return worst
    }
}
