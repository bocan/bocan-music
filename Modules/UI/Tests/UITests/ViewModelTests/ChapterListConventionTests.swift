import Foundation
import Testing
@testable import UI

// MARK: - ChapterListConventionTests

/// Source-convention guards for the Phase 21-12-d chapter UI: the views cannot be
/// exercised host-less, so we assert the localized chrome and that seeking goes
/// through the view model's transport path (never AudioEngine) by reading source.
@Suite("Chapter List Convention")
struct ChapterListConventionTests {
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

    @Test("ChapterListView localizes its chrome and seeks via the supplied closure")
    func chapterListChrome() throws {
        let view = try self.source("Transport/ChapterListView.swift")
        #expect(view.contains("Text(localized: \"Chapters\")"))
        #expect(view.contains("No chapters"))
        #expect(view.contains("onSeek"))
    }

    @Test("PodcastTransportControls seeks chapters via vm.scrub, not the engine")
    func transportSeek() throws {
        let controls = try self.source("Transport/PodcastTransportControls.swift")
        #expect(controls.contains("self.vm.scrub(to:"))
        #expect(controls.contains("ChapterListView("))
        #expect(controls.contains("Show chapters"))
    }
}
