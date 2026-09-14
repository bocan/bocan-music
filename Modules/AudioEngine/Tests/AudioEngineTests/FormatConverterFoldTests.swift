@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - FormatConverterFoldTests

/// The stereo fold of a multichannel source (ADR-091 slice 1, #513, #515).
///
/// `AVAudioConverter` treats a channel-count change as a remap unless
/// `downmix` is set: with it off, a 5.1 source with signal only in the
/// surround pair folds to digital silence, which is the "surround channels
/// are muted" report. Every source here is built in memory, so the tests
/// need no fixture and no audio device.
@Suite("FormatConverter stereo fold")
struct FormatConverterFoldTests {
    /// MPEG_5_1_A channel order: L R C LFE Ls Rs.
    private enum Channel {
        static let left = 0
        static let right = 1
        static let leftSurround = 4
        static let rightSurround = 5
    }

    private static let frames: AVAudioFrameCount = 4800
    /// A 0.5 amplitude sine has an RMS of about 0.354; the fold of a single
    /// surround pair measured 0.104 with `downmix` on and 0.000 with it off,
    /// so 0.05 separates "audible" from "muted" with room on both sides.
    private static let audibleRMS: Float = 0.05

    // MARK: - Helpers

    /// A Float32 non-interleaved 6-channel format carrying MPEG_5_1_A.
    private func sixChannelFormat(sampleRate: Double) throws -> AVAudioFormat {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A))
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }

    /// A buffer with a 440 Hz tone at 0.5 amplitude in `toneChannels` and
    /// digital silence everywhere else.
    private func buffer(format: AVAudioFormat, toneIn toneChannels: Set<Int>) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.frames))
        buffer.frameLength = Self.frames
        let channels = try #require(buffer.floatChannelData)
        for channel in 0 ..< Int(format.channelCount) {
            let samples = channels[channel]
            for frame in 0 ..< Int(Self.frames) {
                let t = Double(frame) / format.sampleRate
                samples[frame] = toneChannels.contains(channel) ? Float(0.5 * sin(440 * 2 * .pi * t)) : 0
            }
        }
        return buffer
    }

    private func rms(_ buffer: AVAudioPCMBuffer, channel: Int) throws -> Float {
        let channels = try #require(buffer.floatChannelData)
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for frame in 0 ..< count {
            let sample = channels[channel][frame]
            sum += sample * sample
        }
        return (sum / Float(count)).squareRoot()
    }

    private func stereo(_ sampleRate: Double) throws -> AVAudioFormat {
        try #require(StereoLayout.format(sampleRate: sampleRate))
    }

    /// Fold `source` to stereo at `outputRate` and return (L, R) RMS.
    private func foldRMS(_ source: AVAudioPCMBuffer, to outputRate: Double) throws -> (left: Float, right: Float) {
        let converter = try FormatConverter(sourceFormat: source.format, targetFormat: self.stereo(outputRate))
        let folded = try #require(try converter.convert(source))
        #expect(folded.frameLength > 0)
        return try (self.rms(folded, channel: Channel.left), self.rms(folded, channel: Channel.right))
    }

    // MARK: - Surround-only source

    @Test("surrounds fold into both stereo channels at the same rate")
    func surroundsAudibleAtSameRate() throws {
        let format = try sixChannelFormat(sampleRate: 48000)
        let source = try buffer(format: format, toneIn: [Channel.leftSurround, Channel.rightSurround])
        let (left, right) = try foldRMS(source, to: 48000)
        #expect(left > Self.audibleRMS, "left is \(left)")
        #expect(right > Self.audibleRMS, "right is \(right)")
    }

    @Test("surrounds fold into both stereo channels while resampling")
    func surroundsAudibleAcrossRates() throws {
        let format = try sixChannelFormat(sampleRate: 48000)
        let source = try buffer(format: format, toneIn: [Channel.leftSurround, Channel.rightSurround])
        let (left, right) = try foldRMS(source, to: 44100)
        #expect(left > Self.audibleRMS, "left is \(left)")
        #expect(right > Self.audibleRMS, "right is \(right)")
    }

    // MARK: - Front-only source

    @Test("a front-only source folds louder than a surround-only one")
    func frontLouderThanSurround() throws {
        let format = try sixChannelFormat(sampleRate: 48000)
        let front = try buffer(format: format, toneIn: [Channel.left, Channel.right])
        let surround = try buffer(format: format, toneIn: [Channel.leftSurround, Channel.rightSurround])
        let frontFold = try foldRMS(front, to: 48000)
        let surroundFold = try foldRMS(surround, to: 48000)
        #expect(frontFold.left > Self.audibleRMS)
        #expect(frontFold.right > Self.audibleRMS)
        #expect(frontFold.left > surroundFold.left, "front \(frontFold.left) vs surround \(surroundFold.left)")
        #expect(frontFold.right > surroundFold.right, "front \(frontFold.right) vs surround \(surroundFold.right)")
    }

    // MARK: - Untagged source

    /// The ADR-091 step 3 decision: whether a 6-channel source with no
    /// channel layout needs a default layout before the fold. Measured on
    /// macOS 26, and documented in AVAudioFormat.h: every initializer that
    /// takes a channel count and no layout returns nil above two channels,
    /// so a multichannel `AVAudioFormat` always carries a layout and no
    /// decoder can hand the pump an untagged one. No helper is needed. If a
    /// later AVFoundation starts accepting these, this test fails and the
    /// question reopens.
    @Test("a 6-channel format cannot exist without a layout, so no default layout is needed")
    func untaggedSixChannelFormatIsUnrepresentable() {
        let common = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 6,
            interleaved: false
        )
        #expect(common == nil)

        var description = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 6,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let fromDescription = AVAudioFormat(streamDescription: &description)
        #expect(fromDescription == nil)
    }

    // MARK: - Stereo passthrough

    @Test("a stereo source at the target rate is unchanged by the fold")
    func stereoSourceUnchanged() throws {
        let format = try stereo(48000)
        let source = try buffer(format: format, toneIn: [Channel.left, Channel.right])
        let (left, right) = try foldRMS(source, to: 48000)
        let expected = try rms(source, channel: Channel.left)
        #expect(abs(left - expected) < 0.01, "left \(left) vs source \(expected)")
        #expect(abs(right - expected) < 0.01, "right \(right) vs source \(expected)")
    }
}
