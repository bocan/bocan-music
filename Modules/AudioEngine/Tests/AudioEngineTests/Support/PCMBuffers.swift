@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - PCMBuffers

/// Small builders and readers for `AVAudioPCMBuffer` in the canonical
/// non-interleaved Float32 layout, shared by the crossfade tests (ADR-095).
enum PCMBuffers {
    /// The canonical stereo output format at `sampleRate`.
    static func stereo(sampleRate: Double = 44100) throws -> AVAudioFormat {
        try #require(StereoLayout.format(sampleRate: sampleRate))
    }

    /// A buffer of `frames` frames with every sample of every channel set to `value`.
    static func constant(_ value: Float, frames: Int, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let buffer = try self.empty(capacity: frames, format: format)
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = try #require(buffer.floatChannelData)
        for channel in 0 ..< Int(format.channelCount) {
            for frame in 0 ..< frames {
                channels[channel][frame] = value
            }
        }
        return buffer
    }

    /// An empty buffer that can hold `capacity` frames.
    static func empty(capacity: Int, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)))
    }

    /// The samples of `channel`, up to `frameLength`.
    static func samples(_ buffer: AVAudioPCMBuffer, channel: Int = 0) throws -> [Float] {
        let channels = try #require(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)))
    }
}
