import Foundation
import Testing
@testable import UI

// MARK: - GlobalSearchFilterConventionTests

/// Source-convention checks that the toolbar search field filters every
/// browse destination, not just Songs / Albums / Artists (#398): Genres,
/// Composers, Radio, and the Podcasts surfaces filter client-side on a
/// `searchQuery` value passed down from `ContentPane`. The filtering itself
/// cannot be exercised host-less, so these pin the structural wiring.
@Suite("Global search filter source conventions")
struct GlobalSearchFilterConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("ContentPane passes the query into every filtering destination")
    func contentPanePassesQuery() throws {
        let source = try self.source("Sources/UI/AppRoot/ContentPane.swift")
        for call in [
            "GenresView(library: self.vm, searchQuery: self.vm.searchQuery)",
            "ComposersView(library: self.vm, searchQuery: self.vm.searchQuery)",
            "PodcastsHomeView(vm: self.vm.podcasts, library: self.vm, searchQuery: self.vm.searchQuery)",
            " RadioView(library: self.vm, searchQuery: self.vm.searchQuery)",
        ] {
            #expect(source.contains(call), "\(call) must receive the live query")
        }
        // Multi-line call; the parameter is enough to pin the wiring.
        let show = try #require(source.range(of: "PodcastShowView("))
        #expect(source[show.lowerBound...].prefix(220).contains("searchQuery: self.vm.searchQuery"))
    }

    @Test("genre and composer listings render the filtered arrays in both modes")
    func genresComposersFilter() throws {
        let genres = try self.source("Sources/UI/Browse/GenresView.swift")
        #expect(genres.contains("List(self.visibleGenres"))
        #expect(genres.contains("models: self.visibleGenres.map"))
        let composers = try self.source("Sources/UI/Browse/ComposersView.swift")
        #expect(composers.contains("List(self.visibleComposers"))
        #expect(composers.contains("models: self.visibleComposers.map"))
    }

    @Test("radio filters stations on name, stream URL, and home page")
    func radioFilter() throws {
        let source = try self.source("Sources/UI/Browse/Radio/RadioView.swift")
        #expect(source.contains("ForEach(self.visibleStations)"))
        #expect(source.contains("station.name.localizedCaseInsensitiveContains(query)"))
        #expect(source.contains("station.streamURL.localizedCaseInsensitiveContains(query)"))
        #expect(source.contains("station.homePageURL?.localizedCaseInsensitiveContains(query)"))
    }

    @Test("podcast grid renders the filtered shows and the episode list honours the query")
    func podcastsFilter() throws {
        let home = try self.source("Sources/UI/Browse/Podcasts/PodcastsHomeView.swift")
        #expect(home.contains("show.title.localizedCaseInsensitiveContains(query)"))
        #expect(home.contains("show.author?.localizedCaseInsensitiveContains(query)"))
        let grid = try self.source("Sources/UI/Browse/Podcasts/PodcastsGridView.swift")
        #expect(grid.contains("ForEach(self.shows"), "the grid must render the filtered shows, not the raw VM array")
        let episodes = try self.source("Sources/UI/Browse/Podcasts/EpisodeList.swift")
        #expect(episodes.contains("global.isEmpty || title.localizedCaseInsensitiveContains(global)"))
    }

    @Test("every filtered listing offers a no-results empty state")
    func noResultsStates() throws {
        for path in [
            "Sources/UI/Browse/GenresView.swift",
            "Sources/UI/Browse/ComposersView.swift",
            "Sources/UI/Browse/Radio/RadioView.swift",
            "Sources/UI/Browse/Podcasts/PodcastsHomeView.swift",
        ] {
            let source = try self.source(path)
            #expect(
                source.contains("L10n.string(\"No Results\")"),
                "\(path) must distinguish a filtered-empty state from a truly empty one"
            )
        }
    }
}
