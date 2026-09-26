// @preconcurrency: AVAudioFormat/AVAudioPCMBuffer lack Sendable; a queue
// belongs to one PumpSource and is only touched on its pump's executor.
// Remove once AVFoundation adopts Sendable annotations (FB13119463).
@preconcurrency import AVFoundation
import Foundation

// MARK: - PCMFrameQueue

/// Output-format frames that a source has converted but the pump has not yet
/// scheduled (ADR-095, slice 2b).
///
/// A decoder read gives a buffer of whatever length the converter produced.
/// A crossfade needs frame-exact cuts: the last unmixed buffer ends on the
/// boundary frame, and each mixed buffer takes the same number of frames from
/// both tracks. The queue holds the converted frames so the pump can take
/// exactly as many as it needs and keep the rest for the next buffer.
///
/// Non-interleaved Float32 only, which is the canonical output format.
final class PCMFrameQueue {
    let format: AVAudioFormat
    private var channels: [[Float]]

    init(format: AVAudioFormat) {
        self.format = format
        self.channels = Array(repeating: [], count: Int(format.channelCount))
    }

    /// Frames waiting in the queue.
    var count: Int {
        self.channels.first?.count ?? 0
    }

    /// Add every frame of `buffer` to the back of the queue.
    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.format == self.format, !buffer.format.isInterleaved,
              let data = buffer.floatChannelData else {
            throw AudioEngineError.crossfadeBufferMismatch(
                reason: "queued buffer is \(buffer.format), queue holds \(self.format)"
            )
        }
        let frames = Int(buffer.frameLength)
        for channel in self.channels.indices {
            self.channels[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: frames))
        }
    }

    /// Remove up to `frames` frames from the front of the queue and return
    /// them as a new buffer. `nil` when the queue is empty or `frames` is not
    /// positive.
    func take(_ frames: Int) -> AVAudioPCMBuffer? {
        let taken = min(frames, self.count)
        guard taken > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: AVAudioFrameCount(taken)),
              let data = buffer.floatChannelData else { return nil }
        for channel in self.channels.indices {
            self.channels[channel].withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                data[channel].update(from: base, count: taken)
            }
            self.channels[channel].removeFirst(taken)
        }
        buffer.frameLength = AVAudioFrameCount(taken)
        return buffer
    }

    /// Drop every queued frame.
    func removeAll() {
        for channel in self.channels.indices {
            self.channels[channel].removeAll(keepingCapacity: true)
        }
    }
}
