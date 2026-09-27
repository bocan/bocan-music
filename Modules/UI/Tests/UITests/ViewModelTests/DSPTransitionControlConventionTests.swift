import Foundation
import Testing
@testable import UI

// MARK: - DSPTransitionControlConventionTests

/// The Effects pane's transition controls each carry an accessibility
/// identifier. The E2E identifier audit sees the "Keep gapless within albums"
/// toggle only while crossfade is above 0, which is how it went without one
/// from Phase 9 until an E2E run on 2026-09-27. A source convention, because
/// the Settings pane cannot be rendered host-less.
@Suite("DSPView transition control conventions")
struct DSPTransitionControlConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/\(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the crossfade slider and the gapless-within-albums toggle both carry identifiers")
    func transitionControlsCarryIdentifiers() throws {
        let view = try self.source("DSP/DSPView.swift")
        #expect(view.contains(".accessibilityIdentifier(A11y.SettingsIDs.crossfade)"))
        #expect(view.contains(".accessibilityIdentifier(A11y.SettingsIDs.crossfadeAlbumGapless)"))
        #expect(A11y.SettingsIDs.crossfadeAlbumGapless.hasPrefix("settings.effects."))
    }
}
