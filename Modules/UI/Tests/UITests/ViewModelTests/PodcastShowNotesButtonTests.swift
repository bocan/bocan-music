import Foundation
import Testing
@testable import UI

// MARK: - PodcastShowNotesButtonTests

/// Source-convention guards for the player-bar Show Notes affordance. The
/// transport row cannot be exercised host-less, so we assert the button's
/// presence, gating, and sheet wiring by reading the source.
@Suite("Podcast Show Notes button")
struct PodcastShowNotesButtonTests {
    private func uiSource(_ relativePath: String) throws -> String {
        let sourcesRoot = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appending(path: "Sources/UI")
        return try String(contentsOf: sourcesRoot.appending(path: relativePath), encoding: .utf8)
    }

    @Test("Transport row has an info.circle button that opens ShowNotesView")
    func transportHasShowNotesButton() throws {
        let source = try uiSource("Transport/PodcastTransportControls.swift")
        #expect(source.contains("info.circle"))
        #expect(source.contains("showingShowNotes"))
        #expect(source.contains("ShowNotesView("))
        // Gated on a podcast being the now-playing item.
        #expect(source.contains("if self.vm.podcastID != nil"))
    }

    @Test("View model resolves the now-playing episode and show hosts")
    func viewModelLoadsNowPlayingShowNotes() throws {
        let source = try uiSource("Browse/Podcasts/PodcastsViewModel.swift")
        #expect(source.contains("func loadNowPlayingShowNotes(podcastID: Int64, guid: String)"))
        #expect(source.contains("var nowPlayingEpisode: EpisodeListItem?"))
        #expect(source.contains("var nowPlayingShowPersons: [PodcastPerson]"))
        // The clear path must reset the new fields so they do not leak across tracks.
        #expect(source.contains("self.nowPlayingEpisode = nil"))
    }

    @Test("Now Playing strip feeds the episode and hosts into the transport row")
    func stripWiresShowNotesData() throws {
        let source = try uiSource("AppRoot/NowPlayingStrip.swift")
        #expect(source.contains("episode: self.library.podcasts.nowPlayingEpisode"))
        #expect(source.contains("showPersons: self.library.podcasts.nowPlayingShowPersons"))
        #expect(source.contains("loadNowPlayingShowNotes(podcastID:"))
    }
}
