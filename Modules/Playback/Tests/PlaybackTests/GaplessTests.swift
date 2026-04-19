@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import Playback

// MARK: - GaplessTests

//
// These tests cover the *format compatibility* logic in `FormatBridge`.
// Full audio playback gapless tests require real audio fixtures and are
// integration-tested manually (or in a separate CI target with test audio).

@Suite("FormatBridge")
struct GaplessTests {
    // MARK: - Compatible pairs

    @Test("same rate + same channels = compatible")
    func sameRateChannels() {
        let bridge = FormatBridge()
        let a = self.makeFmt(sampleRate: 44100, channels: 2)
        let b = self.makeFmt(sampleRate: 44100, channels: 2)
        #expect(bridge.isCompatible(a, b))
    }

    @Test("different sample rates = incompatible")
    func differentSampleRates() {
        let bridge = FormatBridge()
        let a = self.makeFmt(sampleRate: 44100, channels: 2)
        let b = self.makeFmt(sampleRate: 48000, channels: 2)
        #expect(!bridge.isCompatible(a, b))
    }

    @Test("different channel counts = incompatible")
    func differentChannelCounts() {
        let bridge = FormatBridge()
        let a = self.makeFmt(sampleRate: 44100, channels: 2)
        let b = self.makeFmt(sampleRate: 44100, channels: 1)
        #expect(!bridge.isCompatible(a, b))
    }

    @Test("AudioSourceFormat compatibility is symmetric")
    func audioSourceFormatSymmetric() {
        let bridge = FormatBridge()
        let fmt1 = AudioSourceFormat(sampleRate: 44100, bitDepth: 16, channelCount: 2, isInterleaved: false, codec: "flac")
        let fmt2 = AudioSourceFormat(sampleRate: 44100, bitDepth: 24, channelCount: 2, isInterleaved: false, codec: "wav")
        // Bit depth and codec differences should not matter
        #expect(bridge.isCompatible(fmt1, fmt2))
        #expect(bridge.isCompatible(fmt2, fmt1))
    }

    @Test("AudioSourceFormat different sampleRate = incompatible")
    func audioSourceFormatIncompatible() {
        let bridge = FormatBridge()
        let fmt1 = AudioSourceFormat(sampleRate: 44100, bitDepth: 16, channelCount: 2, isInterleaved: false, codec: "flac")
        let fmt2 = AudioSourceFormat(sampleRate: 96000, bitDepth: 24, channelCount: 2, isInterleaved: false, codec: "flac")
        #expect(!bridge.isCompatible(fmt1, fmt2))
    }

    // MARK: - AudioSourceFormat.isGaplessCompatible

    @Test("isGaplessCompatible returns true for same rate+channels")
    func isGaplessCompatible() {
        let a = AudioSourceFormat(sampleRate: 44100, bitDepth: 16, channelCount: 2, isInterleaved: false, codec: "mp3")
        let b = AudioSourceFormat(sampleRate: 44100, bitDepth: 320, channelCount: 2, isInterleaved: false, codec: "mp3")
        #expect(a.isGaplessCompatible(with: b))
    }

    @Test("isGaplessCompatible returns false for mono vs stereo")
    func isGaplessCompatibleMono() {
        let stereo = AudioSourceFormat(sampleRate: 44100, bitDepth: 16, channelCount: 2, isInterleaved: false, codec: "flac")
        let mono = AudioSourceFormat(sampleRate: 44100, bitDepth: 16, channelCount: 1, isInterleaved: false, codec: "flac")
        #expect(!stereo.isGaplessCompatible(with: mono))
    }

    // MARK: - Helpers

    private func makeFmt(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    }
}
