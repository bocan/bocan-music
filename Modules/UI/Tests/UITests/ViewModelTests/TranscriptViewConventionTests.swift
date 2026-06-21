import Foundation
import Testing
@testable import UI

// MARK: - TranscriptViewConventionTests

/// Source-convention guards for the Phase 21-12-b transcript viewer: the view and
/// its two entry points cannot be exercised host-less, so we assert the structural
/// facts (localized chrome, empty state, gated entry points) by reading the source.
@Suite("Transcript View Convention")
struct TranscriptViewConventionTests {
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

    @Test("TranscriptView localizes its chrome and shows an empty state")
    func transcriptViewChrome() throws {
        let view = try self.source("Browse/Podcasts/TranscriptView.swift")
        #expect(view.contains("Text(localized: \"Transcript\")"))
        #expect(view.contains("No transcript available for this episode."))
        #expect(view.contains("ContentUnavailableView"))
        #expect(view.contains("captions.bubble"))
    }

    @Test("TranscriptView and ShowNotesView have a visible Done button mapped to Escape")
    func readOnlySheetsHaveDoneButton() throws {
        for path in ["Browse/Podcasts/TranscriptView.swift", "Browse/Podcasts/ShowNotesView.swift"] {
            let view = try self.source(path)
            #expect(view.contains("L10n.string(\"Done\")"), "\(path) needs a visible Done button")
            #expect(view.contains("self.dismiss()"), "\(path) Done button must dismiss")
            #expect(view.contains(".keyboardShortcut(.cancelAction)"), "\(path) Done must map to Escape")
        }
    }

    @Test("EpisodeList gates the Transcript menu item on transcript_url")
    func episodeListEntryPoint() throws {
        let list = try self.source("Browse/Podcasts/EpisodeList.swift")
        #expect(list.contains("L10n.string(\"Transcript\")"))
        #expect(list.contains("item.episode.transcriptURL != nil"))
        #expect(list.contains("TranscriptView("))
    }

    @Test("Now Playing transport gates the transcript button on a podcast episode")
    func nowPlayingEntryPoint() throws {
        let controls = try self.source("Transport/PodcastTransportControls.swift")
        #expect(controls.contains("L10n.string(\"Transcript\")"))
        #expect(controls.contains("self.vm.podcastID != nil"))
        #expect(controls.contains("TranscriptView("))
    }
}
