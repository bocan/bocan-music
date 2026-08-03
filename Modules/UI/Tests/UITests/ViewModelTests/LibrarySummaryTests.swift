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

    @Test("The Audio Quality pane surfaces provenance batch progress with a cancel affordance")
    func provenanceProgressWired() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Summary/LibraryAudioQualityPane.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("self.library.provenanceProgress"),
            "the pane must render the live batch progress (phase 24-3)"
        )
        #expect(
            source.contains("self.library.cancelProvenanceAnalysis()"),
            "a running batch must be cancellable from the pane"
        )
        #expect(
            source.contains("@ObservedObject var library"),
            "the pane must observe the view model or the progress row never updates"
        )
    }

    @Test("The Audio Quality pane surfaces suspected transcodes honestly (phase 24-4)")
    func suspectedTranscodesWired() throws {
        let source = try String(contentsOf: Self.uiSource("Summary/LibraryAudioQualityPane.swift"), encoding: .utf8)
        #expect(
            source.contains("Suspected Transcodes (\\(report.suspectedTranscodeCount))"),
            "the offender disclosure group must exist with its count"
        )
        #expect(
            source.contains("@State private var suspectsExpanded = false"),
            "the offender list must be collapsed by default like the other offender sections"
        )
        #expect(
            source.contains("confident · shelf at"),
            "rows must carry the confidence-and-shelf detail the phase spec fixes"
        )
        #expect(
            source.contains("report.provenanceAnalysedCount > 0"),
            "the offender content must be gated on at least one analysed track"
        )
        #expect(
            source.contains("startProvenanceAnalysis(announce: false)"),
            "the pane must offer an in-place Analyse Now trigger, unannounced (progress shows right here)"
        )
        #expect(
            source.contains(".disabled(report.provenanceUnanalysedCount == 0)"),
            "the trigger must go quiet when nothing awaits analysis"
        )
        #expect(
            source.contains("lossless files awaiting analysis"),
            "the awaiting count must surface beside the trigger so coverage is honest"
        )
    }

    @Test("The provenance footer's multiline copy matches its catalog key exactly (phase 24-4)")
    func footerKeyInCatalog() throws {
        // A multiline Text(localized: \"\"\"...\"\"\") literal resolves to the
        // joined single-line key; if the catalog entry drifts even one word,
        // the copy silently renders unlocalized. Pin the two together.
        let source = try String(contentsOf: Self.uiSource("Summary/LibraryAudioQualityPane.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "localized: \"\"\"\n"))
        let tail = source[start.upperBound...]
        let end = try #require(tail.range(of: "\"\"\""))
        let joined = tail[..<end.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix("\\") ? String($0.dropLast()) : $0 }
            .joined()
        #expect(joined.contains("ever suspected"), "the copy must keep the suspected-never-accused stance")

        let data = try Data(contentsOf: Self.uiSource("Resources/Localizable.xcstrings"))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        #expect(strings[joined] != nil, "the footer copy must exist as a catalog key, got: \(joined)")
    }

    /// Path to a file under `Modules/UI/Sources/UI/`.
    private static func uiSource(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/\(relativePath)")
    }
}
