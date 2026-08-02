import Foundation
import Testing
@testable import UI

// MARK: - LibrarySummaryTests

/// Structural checks for the Library Summary window's tab strip (#373).
@Suite("Library Summary tabs")
struct LibrarySummaryTests {
    @Test("The six agreed sections exist, Basic Info first")
    func tabRoster() {
        let tabs = LibrarySummaryTab.allCases
        #expect(tabs.count == 6)
        #expect(tabs.first == .basicInfo)
        #expect(tabs.last == .podcasts)
    }

    @Test("Every tab has a label and a distinct symbol")
    func tabPresentation() {
        let tabs = LibrarySummaryTab.allCases
        for tab in tabs {
            #expect(!tab.displayName.isEmpty)
            #expect(!tab.systemImage.isEmpty)
        }
        #expect(Set(tabs.map(\.systemImage)).count == tabs.count, "symbols must not repeat across tabs")
        #expect(Set(tabs.map(\.displayName)).count == tabs.count, "labels must not repeat across tabs")
    }

    @Test("The Library Hygiene tab renders the hygiene pane, not Coming Soon")
    func hygienePaneWired() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Summary/LibrarySummaryView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("LibraryHygienePane(repository: self.statsRepository, library: self.library)"),
            "the hygiene tab must render LibraryHygienePane with navigation wiring"
        )
        #expect(
            source.contains("LibraryAudioQualityPane(repository: self.statsRepository, library: self.library)"),
            "the audio quality tab must render LibraryAudioQualityPane with navigation wiring"
        )
    }
}
