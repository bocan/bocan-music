import Foundation
import Testing

/// The artist lookup pass sends the whole library's artist ids to
/// MusicBrainz, so it may only run while Deep Dive is on (#413).
@Suite("Deep Dive enrichment gate wiring")
struct DeepDiveEnrichmentGateTests {
    @Test("BocanApp starts the pass only through the gate")
    func appUsesTheGate() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/BocanApp.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.contains("await artistEnrichment.start()"))
        #expect(source.contains("DeepDiveEnrichmentGate(service: artistEnrichment)"))
        #expect(source.contains("let deepDiveEnrichmentGate: DeepDiveEnrichmentGate"))
    }
}
