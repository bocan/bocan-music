import Foundation
import Testing
@testable import UI

// MARK: - PodcastFundingConventionTests

/// Source-convention guards for the Phase 21-12-c funding affordance: the view
/// cannot be exercised host-less, so we assert the gating, confirmation, and
/// verbatim-label facts by reading the source.
@Suite("Podcast Funding Convention")
struct PodcastFundingConventionTests {
    private var uiSourcesURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: self.uiSourcesURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("PodcastShowView gates the funding affordance and confirms before opening")
    func fundingAffordance() throws {
        let view = try self.source("Browse/Podcasts/PodcastShowView.swift")
        #expect(view.contains("self.fundingLink"))
        #expect(view.contains("Open this funding link?"))
        #expect(view.contains("Open in Browser"))
        #expect(view.contains("Support this show in your browser"))
        #expect(view.contains("Text(verbatim: label)"))
        #expect(view.contains("pendingFunding"))
    }
}
