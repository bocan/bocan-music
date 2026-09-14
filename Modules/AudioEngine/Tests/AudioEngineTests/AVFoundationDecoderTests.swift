@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

// MARK: - AVFoundationDecoder tests

@Suite("AVFoundationDecoder")
struct AVFoundationDecoderTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "Missing fixture: \(name)")
    }

    // MARK: - Basic decode

    @Test("WAV: reads expected frame count")
    func wavFrameCount() async throws {
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let decoder = try AVFoundationDecoder(url: url)

        let expectedFrames = AVAudioFrameCount(decoder.sourceFormat.sampleRate * decoder.duration)
        var totalFrames: AVAudioFrameCount = 0
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decoder.sourceFormat, frameCapacity: 4096))
        while true {
            let n = try await decoder.read(into: buf)
            if n == 0 {
                break
            }
            totalFrames += n
        }
        await decoder.close()

        // Allow ±5% tolerance for encoder padding.
        let tolerance = Double(expectedFrames) * 0.05
        #expect(abs(Int(totalFrames) - Int(expectedFrames)) < Int(tolerance) + 100)
    }

    @Test("FLAC: duration ≈ 1 s")
    func flacDuration() throws {
        let url = try fixtureURL("sine-1s-44100-24-stereo.flac")
        let decoder = try AVFoundationDecoder(url: url)
        #expect(abs(decoder.duration - 1.0) < 0.05)
    }

    @Test("MP3: opens and has positive duration")
    func mp3Opens() throws {
        let url = try fixtureURL("sample.mp3")
        let decoder = try AVFoundationDecoder(url: url)
        #expect(decoder.duration > 0)
    }

    @Test("AAC M4A: reads frames successfully")
    func aacReads() async throws {
        let url = try fixtureURL("sample-aac.m4a")
        let decoder = try AVFoundationDecoder(url: url)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decoder.sourceFormat, frameCapacity: 4096))
        let n = try await decoder.read(into: buf)
        #expect(n > 0)
        await decoder.close()
    }

    @Test("ALAC M4A: reads frames successfully")
    func alacReads() async throws {
        let url = try fixtureURL("sample-alac.m4a")
        let decoder = try AVFoundationDecoder(url: url)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decoder.sourceFormat, frameCapacity: 4096))
        let n = try await decoder.read(into: buf)
        #expect(n > 0)
        await decoder.close()
    }

    // MARK: - Seek

    @Test("WAV: seek to 0.5 s then read")
    func wavSeek() async throws {
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let decoder = try AVFoundationDecoder(url: url)
        try await decoder.seek(to: 0.5)

        let pos = await decoder.position
        #expect(abs(pos - 0.5) < 0.05, "position after seek should be ≈ 0.5 s, got \(pos)")

        let buf = try #require(AVAudioPCMBuffer(pcmFormat: decoder.sourceFormat, frameCapacity: 4096))
        let n = try await decoder.read(into: buf)
        #expect(n > 0, "should still have frames after seeking to 0.5 s of 1 s file")
        await decoder.close()
    }

    @Test("WAV: seek out-of-range throws")
    func wavSeekOutOfRange() async throws {
        let url = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let decoder = try AVFoundationDecoder(url: url)
        await #expect(throws: AudioEngineError.self) {
            try await decoder.seek(to: 999.0)
        }
        await decoder.close()
    }

    // MARK: - Multichannel (ADR-091, #515)

    /// A 5.1 file at the output's own rate, end to end through the pump.
    /// Before ADR-091 slice 1 the pump built no converter for it and asked
    /// `AVAudioFile` to read six channels into a stereo buffer, which fails
    /// with `decoderFailure` (OSStatus -50) and stops the song. The pump must
    /// now read in the file's own format, fold, and schedule with no error.
    @Test("5.1 ALAC at the output rate folds and schedules with no error")
    func surroundALACPumpsAtOutputRate() async throws {
        // `@unchecked Sendable`: written once by `onError`, read after the
        // pump has stopped.
        final class Sink: @unchecked Sendable { var error: Error? }

        let url = try fixtureURL("surround-lsrs-48000.m4a")
        let decoder = try AVFoundationDecoder(url: url)
        #expect(decoder.sourceFormat.channelCount == 6)
        #expect(decoder.sourceFormat.sampleRate == 48000)

        let graph = EngineGraph()
        let output = try #require(StereoLayout.format(sampleRate: 48000))
        let pump = try BufferPump(decoder: decoder, playerNode: graph.playerNode, outputFormat: output)
        let sink = Sink()
        await pump.start(onEnded: {}, onError: { sink.error = $0 })

        // The fixture is a quarter second, so the pump schedules one or two
        // buffers and reaches EOF; wait for the first rather than a fixed sleep.
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
        #expect(scheduled > 0, "the pump scheduled nothing")
    }

    // MARK: - Error paths

    @Test("Missing file → fileNotFound")
    func missingFile() throws {
        let url = URL(fileURLWithPath: "/nonexistent/file.wav")
        #expect(throws: AudioEngineError.self) {
            _ = try AVFoundationDecoder(url: url)
        }
    }

    /// Before ADR-091 slice 3 every open failure was `accessDenied`, which
    /// `DecoderFactory` rethrows without trying FFmpeg; a format refusal must
    /// be a `decoderFailure` so the fallback can fire.
    @Test("a format AVFoundation refuses throws decoderFailure, not accessDenied")
    func refusedFormatIsDecoderFailure() throws {
        let url = try fixtureURL("mp3-in-mp4.m4a")
        do {
            _ = try AVFoundationDecoder(url: url)
            Issue.record("AVFoundation opened MP3 in MP4; the fixture no longer proves a refusal")
        } catch let AudioEngineError.decoderFailure(codec, _) {
            #expect(codec == "AVFoundation")
        } catch {
            Issue.record("expected decoderFailure, got \(error)")
        }
    }

    @Test("a file without read permission throws accessDenied")
    func unreadableFileIsAccessDenied() throws {
        let source = try fixtureURL("sine-1s-44100-16-stereo.wav")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noperm-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: source, to: url)
        // Unlinking needs the directory's permission, not the file's, so the
        // mode never has to be restored before removal.
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        do {
            _ = try AVFoundationDecoder(url: url)
            Issue.record("a mode 000 file opened; is this running as root?")
        } catch let AudioEngineError.accessDenied(thrownURL, _) {
            #expect(thrownURL == url)
        } catch {
            Issue.record("expected accessDenied, got \(error)")
        }
    }
}
