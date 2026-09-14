@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - FormatOnlyDecoder

/// A decoder that carries nothing but a source format. The pump's converter
/// decision is made in `init`, before any read, so these tests never start
/// the pump and never touch an audio device.
private final class FormatOnlyDecoder: Decoder, @unchecked Sendable {
    let sourceFormat: AVAudioFormat
    let duration: TimeInterval = 0
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

    func read(into _: AVAudioPCMBuffer) async throws -> AVAudioFrameCount {
        0
    }

    func seek(to _: TimeInterval) async throws {}
    func close() async {}
}

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
            decoder: FormatOnlyDecoder(format: source),
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
