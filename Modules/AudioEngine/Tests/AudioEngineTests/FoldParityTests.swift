@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - FoldParityTests

/// One fold for both routes (#522). Before this, an FFmpeg-decoded surround
/// file was folded to stereo by swresample inside the decoder while an
/// AVFoundation-decoded one was folded by `AVAudioConverter` in the pump,
/// and the two folds put the same surround channel about 1.9 dB apart.
/// `FFmpegDecoder` now keeps the file's own channels and the engine's one
/// `FormatConverter` folds every route.
@Suite("Stereo fold parity between decoder routes")
struct FoldParityTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "Missing fixture: \(name)")
    }

    /// Decodes about a fifth of a second from `decoder` in its own format and
    /// folds it to stereo through `FormatConverter`, returning (L, R) RMS.
    private func foldedRMS(_ decoder: any Decoder) async throws -> (left: Float, right: Float) {
        let source = decoder.sourceFormat
        let stereo = try #require(StereoLayout.format(sampleRate: source.sampleRate))
        let converter = try FormatConverter(sourceFormat: source, targetFormat: stereo)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 9600))
        // Skip the first buffer: codec priming and the E-AC-3 delay make it quiet.
        _ = try await decoder.read(into: buffer)
        buffer.frameLength = 0
        let frames = try await decoder.read(into: buffer)
        #expect(frames > 0)
        let folded = try #require(try converter.convert(buffer))
        let channels = try #require(folded.floatChannelData)
        func rms(_ channel: Int) -> Float {
            let count = Int(folded.frameLength)
            var sum: Float = 0
            for frame in 0 ..< count {
                let sample = channels[channel][frame]
                sum += sample * sample
            }
            return count > 0 ? (sum / Float(count)).squareRoot() : 0
        }
        return (rms(0), rms(1))
    }

    @Test("a raw E-AC-3 keeps its six channels and folds audibly through the engine's converter")
    func rawEAC3FoldsThroughTheConverter() async throws {
        let decoder = try FFmpegDecoder(url: fixtureURL("surround-lsrs-48000.eac3"))
        #expect(decoder.sourceFormat.channelCount == 6)
        #expect(decoder.sourceFormat.channelLayout?.layoutTag == kAudioChannelLayoutTag_UseChannelDescriptions)
        let (left, right) = try await foldedRMS(decoder)
        await decoder.close()
        #expect(left > 0.05, "left is \(left)")
        #expect(right > 0.05, "right is \(right)")
    }

    /// The same second of surround-only E-AC-3, once raw (FFmpeg route) and
    /// once in MP4 (AVFoundation route), folded by the same converter, lands
    /// within half a decibel. Before #522 the raw file arrived pre-folded by
    /// swresample and measured about 1.9 dB lower.
    @Test("the same mix folds to the same level on the FFmpeg and AVFoundation routes")
    func bothRoutesFoldToTheSameLevel() async throws {
        let ffmpeg = try FFmpegDecoder(url: fixtureURL("surround-lsrs-1s-48000.eac3"))
        let avFoundation = try AVFoundationDecoder(url: fixtureURL("surround-lsrs-1s-eac3-48000.m4a"))
        let viaFFmpeg = try await foldedRMS(ffmpeg)
        let viaAVFoundation = try await foldedRMS(avFoundation)
        await ffmpeg.close()
        await avFoundation.close()

        let ratio = 20 * log10(Double(viaFFmpeg.left) / Double(viaAVFoundation.left))
        #expect(abs(ratio) < 0.5, "FFmpeg \(viaFFmpeg.left) vs AVFoundation \(viaAVFoundation.left): \(ratio) dB apart")
    }

    @Test("a raw TrueHD keeps its six channels")
    func rawTrueHDKeepsChannels() async throws {
        let decoder = try FFmpegDecoder(url: fixtureURL("surround-lsrs-48000.thd"))
        #expect(decoder.sourceFormat.channelCount == 6)
        let (left, right) = try await foldedRMS(decoder)
        await decoder.close()
        #expect(left > 0.05, "left is \(left)")
        #expect(right > 0.05, "right is \(right)")
    }

    @Test("a stereo FFmpeg source is untouched by the change")
    func stereoSourceStaysStereo() throws {
        let decoder = try FFmpegDecoder(url: fixtureURL("sine-1s-48000-stereo.ogg"))
        #expect(decoder.sourceFormat.channelCount == 2)
        #expect(decoder.sourceFormat.channelLayout?.layoutTag == kAudioChannelLayoutTag_Stereo)
    }

    /// End to end: the pump folds a raw E-AC-3 exactly as it folds a 5.1 ALAC.
    @Test("a raw E-AC-3 pumps to a stereo output with no error")
    func rawEAC3PumpsAtOutputRate() async throws {
        final class Sink: @unchecked Sendable { var error: Error? }
        let decoder = try FFmpegDecoder(url: fixtureURL("surround-lsrs-48000.eac3"))
        let graph = EngineGraph()
        let output = try #require(StereoLayout.format(sampleRate: 48000))
        let pump = try BufferPump(decoder: decoder, playerNode: graph.playerNode, outputFormat: output)
        let pumpFormat = await pump.pumpFormat
        #expect(pumpFormat.channelCount == 6)
        let sink = Sink()
        await pump.start(onEnded: {}, onError: { sink.error = $0 })
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await pump.scheduledBufferCount > 0 || sink.error != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let scheduled = await pump.scheduledBufferCount
        await pump.stop()
        await decoder.close()
        #expect(sink.error == nil, "the pump reported \(String(describing: sink.error))")
        #expect(scheduled > 0)
    }
}
