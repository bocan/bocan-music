import Foundation
import Testing
@testable import AudioEngine

@Suite("DecodeSmokeCheck")
struct DecodeSmokeCheckTests {
    private func fixture(_ name: String) throws -> String {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url).path
    }

    @Test("every format the smoke test lists decodes to audible samples")
    func decodesEachFormat() async throws {
        let names = [
            "sample.mp3", "sine-1s-44100-24-stereo.flac", "sine-1s-48000-stereo.ogg",
            "sine-1s-48000-stereo.opus", "opus-in-mp4.m4a", "sample-aac.m4a",
            "sample-alac.m4a", "sine-1s-44100-16-stereo.wav", "sine-1s-44100-stereo.wv",
        ]
        let outcomes = try await DecodeSmokeCheck.run(sources: names.map(self.fixture))
        #expect(outcomes.count == names.count)
        for outcome in outcomes {
            #expect(outcome.passed, "\(outcome.source): \(outcome.failure ?? "")")
            #expect(outcome.frames > 0)
            #expect(outcome.peak > 0)
        }
    }

    @Test("a missing file and a corrupt file are reported, not thrown")
    func reportsFailures() async throws {
        let outcomes = try await DecodeSmokeCheck.run(sources: [
            "/nonexistent/none.flac",
            self.fixture("corrupt.mp3"),
        ])
        #expect(outcomes.count == 2)
        #expect(outcomes[0].passed == false)
        #expect(outcomes[0].failure?.hasPrefix("open failed") == true)
        #expect(outcomes[1].passed == false)
    }
}
