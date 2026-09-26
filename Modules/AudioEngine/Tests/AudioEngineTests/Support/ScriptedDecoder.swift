@preconcurrency import AVFoundation
import Foundation
@testable import AudioEngine

// MARK: - ScriptedDecoder

/// The one fake `Decoder` for AudioEngine tests (ADR-095, slice 1). It
/// replaces four private copies that differed only in how much audio they
/// produced.
///
/// It produces `signal` for exactly `frames` frames and then reports
/// end-of-stream, or never ends when `frames` is `nil`. `duration` defaults to
/// the true length (3600 s for a never-ending source) but can be set to a
/// wrong value on purpose, to test how the pump copes with a container that
/// over- or under-reports its length. It records reads, seeks and closes so a
/// test can assert what the pump did to it.
final class ScriptedDecoder: Decoder, @unchecked Sendable {
    // @unchecked: every mutable field is guarded by `lock`.

    /// What each channel of every produced frame contains.
    enum Signal: Sendable {
        case silence
        /// Every sample is this value.
        case constant(Float)
        /// A sine wave, phase-continuous across reads and seeks.
        case sine(frequency: Double, amplitude: Float)
    }

    let sourceFormat: AVAudioFormat
    let duration: TimeInterval

    private let signal: Signal
    private let totalFrames: AVAudioFramePosition?
    private let lock = NSLock()
    private var cursor: AVAudioFramePosition = 0
    private var reads = 0
    private var closes = 0
    private var seeks: [TimeInterval] = []

    /// - Parameters:
    ///   - format: the source format the pump sees (`sourceFormat`).
    ///   - frames: how many frames to produce before end-of-stream; `0`
    ///     ends at once, `nil` never ends.
    ///   - signal: the audio to produce.
    ///   - reportedDuration: the `duration` to report; defaults to the true
    ///     length.
    init(
        format: AVAudioFormat,
        frames: AVAudioFramePosition?,
        signal: Signal = .silence,
        reportedDuration: TimeInterval? = nil
    ) {
        self.sourceFormat = format
        self.signal = signal
        self.totalFrames = frames
        self.duration = reportedDuration ?? frames.map { Double($0) / format.sampleRate } ?? 3600
    }

    /// The protocol's file initializer: an empty 44.1 kHz stereo source.
    convenience init(url _: URL) throws {
        guard let format = StereoLayout.format(sampleRate: 44100) else {
            throw AudioEngineError.outputDeviceUnavailable
        }
        self.init(format: format, frames: 0)
    }

    // MARK: - Recorded calls

    var readCalls: Int {
        self.lock.withLock { self.reads }
    }

    var closeCalls: Int {
        self.lock.withLock { self.closes }
    }

    var seekTargets: [TimeInterval] {
        self.lock.withLock { self.seeks }
    }

    // MARK: - Decoder

    var position: TimeInterval {
        get async {
            self.lock.withLock { Double(self.cursor) / self.sourceFormat.sampleRate }
        }
    }

    func read(into buffer: AVAudioPCMBuffer) async throws -> AVAudioFrameCount {
        let (start, count) = self.lock.withLock { () -> (AVAudioFramePosition, AVAudioFrameCount) in
            self.reads += 1
            var count = AVAudioFramePosition(buffer.frameCapacity)
            if let total = self.totalFrames {
                count = max(0, min(count, total - self.cursor))
            }
            let start = self.cursor
            self.cursor += count
            return (start, AVAudioFrameCount(count))
        }
        buffer.frameLength = count
        self.fill(buffer, from: start, count: count)
        return count
    }

    func seek(to time: TimeInterval) async throws {
        self.lock.withLock {
            self.seeks.append(time)
            var target = AVAudioFramePosition(time * self.sourceFormat.sampleRate)
            if let total = self.totalFrames {
                target = min(target, total)
            }
            self.cursor = max(0, target)
        }
    }

    func close() async {
        self.lock.withLock { self.closes += 1 }
    }

    // MARK: - Private

    private func fill(_ buffer: AVAudioPCMBuffer, from start: AVAudioFramePosition, count: AVAudioFrameCount) {
        // Formats without float channel data (integer PCM in the format
        // tests) only need the frame count.
        guard count > 0, let channels = buffer.floatChannelData else { return }
        let frames = Int(count)
        let channelCount = Int(buffer.format.channelCount)
        // Interleaved float keeps every channel in buffer 0.
        let stride = buffer.format.isInterleaved ? channelCount : 1
        let planes = buffer.format.isInterleaved ? 1 : channelCount
        for plane in 0 ..< planes {
            let samples = channels[plane]
            for frame in 0 ..< frames {
                let value = self.sample(at: start + AVAudioFramePosition(frame))
                for lane in 0 ..< stride {
                    samples[frame * stride + lane] = value
                }
            }
        }
    }

    private func sample(at frame: AVAudioFramePosition) -> Float {
        switch self.signal {
        case .silence:
            0

        case let .constant(value):
            value

        case let .sine(frequency, amplitude):
            amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / self.sourceFormat.sampleRate))
        }
    }
}
