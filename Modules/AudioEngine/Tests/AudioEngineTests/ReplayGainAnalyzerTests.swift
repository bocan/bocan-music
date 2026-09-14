import Foundation
import Testing
@testable import AudioEngine

// MARK: - ReplayGainAnalyzerTests

/// Loudness of multichannel files (ADR-091 slice 2).
///
/// The analyzer used to take channels 0 and 1 of the file's own format as
/// left and right. Channel order is per container (MP4 ALAC and AAC give
/// C L R Ls Rs LFE, E-AC-3 gives L C R Ls Rs LFE), so that measured the
/// wrong pair, and a mix carried only in the surrounds measured as silence.
/// It now measures the stereo fold, which is what the engine plays.
@Suite("ReplayGainAnalyzer")
struct ReplayGainAnalyzerTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "Missing fixture: \(name)")
    }

    // MARK: - Multichannel

    @Test("a 5.1 mix carried only in the surround pair measures a finite loudness")
    func surroundOnlyMeasuresFinite() async throws {
        let result = try await ReplayGainAnalyzer.analyze(url: self.fixtureURL("surround-lsrs-1s-eac3-48000.m4a"))
        #expect(result.integratedLUFS.isFinite)
        #expect(result.integratedLUFS > -70, "measured \(result.integratedLUFS) LUFS")
        #expect(result.trackPeakLinear > 0)
    }

    @Test("a 5.1 mix carried in the front pair measures louder than the same mix in the surrounds")
    func frontLouderThanSurround() async throws {
        let front = try await ReplayGainAnalyzer.analyze(url: self.fixtureURL("front-lr-1s-eac3-48000.m4a"))
        let surround = try await ReplayGainAnalyzer.analyze(url: self.fixtureURL("surround-lsrs-1s-eac3-48000.m4a"))
        #expect(front.integratedLUFS.isFinite)
        #expect(front.integratedLUFS > -70, "measured \(front.integratedLUFS) LUFS")
        #expect(
            front.integratedLUFS > surround.integratedLUFS,
            "front \(front.integratedLUFS) vs surround \(surround.integratedLUFS)"
        )
    }

    /// The quarter-second ALAC is too short for a loudness block, but its true
    /// peak is measured from every sample. In the MP4 layout channels 0 and 1
    /// are centre and left, both silent here, so the old analyzer saw a peak
    /// of zero; the fold carries the surround tone into both channels.
    @Test("the true peak of a surround-only ALAC comes from the fold, not from channels 0 and 1")
    func surroundOnlyPeakComesFromFold() async throws {
        let result = try await ReplayGainAnalyzer.analyze(url: self.fixtureURL("surround-lsrs-48000.m4a"))
        #expect(result.trackPeakLinear > 0.05, "peak \(result.trackPeakLinear)")
    }

    // MARK: - Stereo unchanged

    /// Pinned from the analyzer before the fold was added, so a stereo file
    /// measures exactly what it did. The fold only exists above two channels.
    @Test("a stereo file measures what it measured before the fold")
    func stereoUnchanged() async throws {
        let result = try await ReplayGainAnalyzer.analyze(url: self.fixtureURL("sine-1s-44100-16-stereo.wav"))
        let pinnedLUFS = -24.7462
        #expect(abs(result.integratedLUFS - pinnedLUFS) < 0.01, "measured \(result.integratedLUFS) LUFS")
    }
}
