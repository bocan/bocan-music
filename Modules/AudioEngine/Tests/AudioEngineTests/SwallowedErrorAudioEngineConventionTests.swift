import Foundation
import Testing
@testable import AudioEngine

// MARK: - SwallowedErrorAudioEngineConventionTests

/// #497: the `try?` audit found three recoveries in this module that were
/// correct but silent (`docs/audits/try-optional-audit.md`, class (b)). The
/// recovery is unchanged, so what needs pinning is the log line that explains
/// it; a log cannot be read back from a test, hence source conventions.
@Suite("Swallowed-error conventions in AudioEngine (#497)")
struct SwallowedErrorAudioEngineConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AudioEngineTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/AudioEngine/
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("both FFmpeg fallbacks log why they could not help")
    func ffmpegFallbackFailuresAreLogged() throws {
        let source = try self.source("Sources/AudioEngine/Decoder/DecoderFactory.swift")
        #expect(!source.contains("try? FFmpegDecoder("), "the fallback's own reason was dropped")
        #expect(source.contains("decoder.ffmpegFallback.failed"))
        #expect(source.contains("decoder.unknownFormat.ffmpegFailed"))
    }

    @Test("a corrupt saved DSP state logs before it resets the user's settings")
    func dspStateDecodeFailureIsLogged() throws {
        let source = try self.source("Sources/AudioEngine/DSP/DSPState.swift")
        #expect(!source.contains("try? JSONDecoder().decode(Self.self"))
        #expect(source.contains("dsp.state.decode_failed"))
        // A missing key is not a failure and must stay silent.
        #expect(source.contains("guard let data = defaults.data(forKey: defaultsKey) else { return Self() }"))
    }
}
