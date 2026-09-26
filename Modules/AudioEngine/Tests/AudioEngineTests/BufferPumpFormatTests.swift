@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - BufferPumpFormatTests

/// The converter decision (ADR-091 slice 1, #515). A pump has a converter if
/// and only if the source differs from the output in sample rate or channel
/// count, and whenever it has one the decoder reads into buffers of its own
/// format. Before this, the decision was made on sample rate alone: a 5.1
/// file at the device's own rate got no converter and was read into a stereo
/// buffer, which `AVAudioFile` refuses.
@Suite("BufferPump converter decision")
struct BufferPumpFormatTests {
    private func surround(_ sampleRate: Double) throws -> AVAudioFormat {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A))
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }

    private func stereo(_ sampleRate: Double) throws -> AVAudioFormat {
        try #require(StereoLayout.format(sampleRate: sampleRate))
    }

    private func makePump(
        in graph: EngineGraph,
        source: AVAudioFormat,
        output: AVAudioFormat
    ) throws -> BufferPump {
        try BufferPump(
            // Only the source format matters: the pump's converter decision is
            // made in `init`, before any read, so the pump is never started.
            decoder: ScriptedDecoder(format: source, frames: 0),
            playerNode: graph.playerNode,
            outputFormat: output
        )
    }

    @Test("a 5.1 source at the output rate gets a converter and reads in its own format")
    func surroundAtOutputRate() async throws {
        let graph = EngineGraph()
        let pump = try makePump(in: graph, source: surround(44100), output: stereo(44100))
        let hasConverter = await pump.hasConverter
        let pumpFormat = await pump.pumpFormat
        #expect(hasConverter)
        #expect(pumpFormat.channelCount == 6)
        #expect(pumpFormat.sampleRate == 44100)
    }

    @Test("a 5.1 source at another rate gets a converter and reads in its own format")
    func surroundAtOtherRate() async throws {
        let graph = EngineGraph()
        let pump = try makePump(in: graph, source: surround(48000), output: stereo(44100))
        let hasConverter = await pump.hasConverter
        let pumpFormat = await pump.pumpFormat
        #expect(hasConverter)
        #expect(pumpFormat.channelCount == 6)
        #expect(pumpFormat.sampleRate == 48000)
    }

    @Test("a stereo source at the output rate gets no converter")
    func stereoAtOutputRate() async throws {
        let graph = EngineGraph()
        let pump = try makePump(in: graph, source: stereo(44100), output: stereo(44100))
        let hasConverter = await pump.hasConverter
        let pumpFormat = await pump.pumpFormat
        #expect(!hasConverter)
        #expect(pumpFormat.channelCount == 2)
        #expect(pumpFormat.sampleRate == 44100)
    }

    @Test("a stereo source at another rate keeps the resampling converter")
    func stereoAtOtherRate() async throws {
        let graph = EngineGraph()
        let pump = try makePump(in: graph, source: stereo(48000), output: stereo(44100))
        let hasConverter = await pump.hasConverter
        let pumpFormat = await pump.pumpFormat
        #expect(hasConverter)
        #expect(pumpFormat.channelCount == 2)
        #expect(pumpFormat.sampleRate == 48000)
    }
}
