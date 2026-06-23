import Foundation
import Testing
@testable import UI

// MARK: - PodcastPodrollUITests

/// Source-convention guards for the podroll "You Might Also Like" shelf. The views
/// cannot be exercised host-less, so we assert the shelf, its data resolution, and
/// the tap-to-discover routing by reading the source.
@Suite("Podcast podroll shelf")
struct PodcastPodrollUITests {
    private func uiSource(_ relativePath: String) throws -> String {
        let sourcesRoot = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appending(path: "Sources/UI")
        return try String(contentsOf: sourcesRoot.appending(path: relativePath), encoding: .utf8)
    }

    @Test("PodrollShelf renders a localized header and resolves each card")
    func shelfStructure() throws {
        let source = try uiSource("Browse/Podcasts/PodrollShelf.swift")
        #expect(source.contains("You Might Also Like"))
        #expect(source.contains("struct PodrollContext"))
        #expect(source.contains("AsyncImage"))
        // Each card resolves title/artwork lazily.
        #expect(source.contains("await self.resolve(url)"))
    }

    @Test("ShowNotesView hosts the podroll shelf above the rest of the notes")
    func showNotesRendersShelf() throws {
        let source = try uiSource("Browse/Podcasts/ShowNotesView.swift")
        #expect(source.contains("var podrollContext: PodrollContext?"))
        #expect(source.contains("PodrollShelf(context: podrollContext)"))
    }

    @Test("View model resolves podroll previews and tracks the now-playing podroll")
    func viewModelPodroll() throws {
        let source = try uiSource("Browse/Podcasts/PodcastsViewModel.swift")
        #expect(source.contains("func resolvePodroll(_ url: URL) async -> PodrollPreview?"))
        #expect(source.contains("var nowPlayingPodroll: [PodcastPodrollItem]"))
        #expect(source.contains("self.nowPlayingPodroll = []"))
    }

    @Test("Tapping a recommendation navigates to Podcasts and opens its detail")
    func recommendationRouting() throws {
        let source = try uiSource("ViewModels/LibraryViewModel.swift")
        #expect(source.contains("func openPodcastRecommendation(_ url: URL)"))
        #expect(source.contains("await self.selectDestination(.podcasts)"))
        #expect(source.contains("await self.podcasts.openDetailForURL(url)"))
    }

    @Test("Both show-notes call sites supply a podroll context")
    func callSitesWirePodroll() throws {
        let episodeList = try uiSource("Browse/Podcasts/EpisodeList.swift")
        #expect(episodeList.contains("podrollContext: PodrollContext("))
        #expect(episodeList.contains("self.library.openPodcastRecommendation"))

        let strip = try uiSource("AppRoot/NowPlayingStrip.swift")
        #expect(strip.contains("podrollContext: PodrollContext("))
        #expect(strip.contains("nowPlayingPodroll"))
    }
}
