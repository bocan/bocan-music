@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

@Suite("PumpSource - reading, counting, seeking")
struct PumpSourceTests {
    @Test("A source in the output format reads and converts without a converter")
    func sameFormatHasNoConverter() async throws {
        let format = try PCMBuffers.stereo(sampleRate: 44100)
        let source = try PumpSource(
            decoder: ScriptedDecoder(format: format, frames: 10000, signal: .constant(0.5)),
            outputFormat: format
        )
        #expect(!source.hasConverter)
        #expect(source.pumpFormat == format)

        let buffer = try #require(source.makeReadBuffer(duration: 0.1))
        #expect(buffer.frameCapacity == 4410)
        let read = try await source.read(into: buffer)
        let converted = try #require(try source.convert(buffer))

        #expect(read == 4410)
        #expect(converted === buffer)
        #expect(source.framesRead == 4410)
        #expect(source.outputFramesProduced == 4410)
    }

    @Test("A source at another rate converts, and counts output frames at the output rate")
    func resamplingCountsOutputFrames() async throws {
        let sourceFormat = try PCMBuffers.stereo(sampleRate: 44100)
        let outputFormat = try PCMBuffers.stereo(sampleRate: 48000)
        let source = try PumpSource(
            decoder: ScriptedDecoder(format: sourceFormat, frames: nil, signal: .constant(0.5)),
            outputFormat: outputFormat
        )
        #expect(source.hasConverter)
        #expect(source.pumpFormat == sourceFormat)

        var produced: AVAudioFramePosition = 0
        for _ in 0 ..< 5 {
            let buffer = try #require(source.makeReadBuffer(duration: 0.2))
            _ = try await source.read(into: buffer)
            if let converted = try source.convert(buffer) {
                #expect(converted.format.sampleRate == 48000)
                produced += AVAudioFramePosition(converted.frameLength)
            }
        }

        #expect(source.framesRead == 5 * 8820)
        #expect(source.outputFramesProduced == produced)
        // One second of 44.1k audio is about one second at 48k; the converter
        // may hold a few frames back, so allow a small shortfall.
        #expect(abs(Double(produced) - 48000) < 200)
    }

    @Test("The segment budget counts down in decoder frames and a source without one has none")
    func segmentBudget() async throws {
        let format = try PCMBuffers.stereo(sampleRate: 44100)
        let budgeted = try PumpSource(
            decoder: ScriptedDecoder(format: format, frames: nil),
            outputFormat: format,
            maxDuration: 0.5
        )
        #expect(budgeted.maxFrames == 22050)
        #expect(budgeted.remainingSegmentFrames == 22050)

        let buffer = try #require(budgeted.makeReadBuffer(duration: 0.2))
        _ = try await budgeted.read(into: buffer)
        let expected: AVAudioFrameCount = 22050 - 8820
        #expect(budgeted.remainingSegmentFrames == expected)

        let unbudgeted = try PumpSource(decoder: ScriptedDecoder(format: format, frames: nil), outputFormat: format)
        #expect(unbudgeted.remainingSegmentFrames == nil)
    }

    @Test("A seek reaches the decoder and restarts the counts, segment budget included")
    func seekRestartsCounts() async throws {
        let format = try PCMBuffers.stereo(sampleRate: 44100)
        let decoder = ScriptedDecoder(format: format, frames: nil)
        let source = try PumpSource(decoder: decoder, outputFormat: format, maxDuration: 1)

        let buffer = try #require(source.makeReadBuffer(duration: 0.2))
        _ = try await source.read(into: buffer)
        _ = try source.convert(buffer)
        #expect(source.framesRead > 0)

        try await source.seek(to: 12.5)

        #expect(decoder.seekTargets == [12.5])
        #expect(source.framesRead == 0)
        #expect(source.outputFramesProduced == 0)
        #expect(source.remainingSegmentFrames == 44100)
    }

    @Test("End of stream reads zero frames and counts nothing")
    func endOfStream() async throws {
        let format = try PCMBuffers.stereo(sampleRate: 44100)
        let source = try PumpSource(decoder: ScriptedDecoder(format: format, frames: 0), outputFormat: format)
        let buffer = try #require(source.makeReadBuffer(duration: 0.2))

        #expect(try await source.read(into: buffer) == 0)
        #expect(source.framesRead == 0)
    }
}
