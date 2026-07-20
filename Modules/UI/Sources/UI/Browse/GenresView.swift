import Persistence
import SwiftUI

// MARK: - GenresView

/// Lists all genres in the library.  Selecting a genre pushes a track list.
public struct GenresView: View {
    public var library: LibraryViewModel

    @State private var genres: [String] = []
    @State private var trackCounts: [String: Int] = [:]
    /// Card data (counts + cover paths) keyed by genre, for grid mode. Loaded
    /// alongside the list fetch so switching modes never refetches.
    @State private var cardData: [String: CollectionCardData] = [:]
    @State private var isLoading = true
    /// Persisted list sort order; defaults to song count (the historical order).
    @AppStorage("genres.sortOrder") private var sortOrder: GenreSortOrder = .songCount
    /// Persisted List vs Grid mode; defaults to List so the view is unchanged
    /// until the user opts in (phase 23-2). String-backed so the "View as" menu's
    /// writes reliably redraw this listing (phase 23-3).
    @CollectionViewModeStorage("genres.viewMode") private var viewMode

    public init(library: LibraryViewModel) {
        self.library = library
    }

    public var body: some View {
        Group {
            if self.isLoading {
                LoadingState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.genres.isEmpty {
                EmptyState(
                    symbol: "tag",
                    title: L10n.string("No Genres"),
                    message: L10n.string("No genre tags found in your library.")
                )
            } else if self.viewMode == .grid {
                self.genreGrid
            } else {
                self.genreList
            }
        }
        .navigationTitle(L10n.string("Genres"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CollectionViewModeToggle(mode: self.$viewMode)
            }
            ToolbarItem(placement: .primaryAction) {
                SortMenu(selection: self.$sortOrder, help: L10n.string("Choose how genres are sorted"))
            }
        }
        .task {
            let trackRepo = TrackRepository(database: self.library.database)
            let albumRepo = AlbumRepository(database: self.library.database)
            async let genresFetch = try? trackRepo.allGenres()
            async let countsFetch = try? trackRepo.genreTrackCounts()
            async let cardsFetch = try? albumRepo.fetchGenreCards()
            let allGenres = await genresFetch ?? []
            self.trackCounts = await countsFetch ?? [:]
            self.cardData = await Dictionary(uniqueKeysWithValues: (cardsFetch ?? []).map { ($0.name, $0) })
            self.genres = self.sortedGenres(allGenres)
            self.isLoading = false
        }
        // Re-sort in place when the user changes the order (no refetch).
        .onChange(of: self.sortOrder) { _, _ in self.genres = self.sortedGenres(self.genres) }
    }

    /// Grid of genre cards, ordered by the same sorted `genres` array the list
    /// uses so the SortMenu reorders both modes identically.
    private var genreGrid: some View {
        CollectionCardGrid(
            models: self.genres.map { name in
                let data = self.cardData[name]
                return CollectionCardModel(
                    id: name,
                    title: name,
                    albumCount: data?.albumCount ?? 0,
                    songCount: data?.songCount ?? self.trackCounts[name] ?? 0,
                    coverArtPaths: data?.coverArtPaths ?? []
                )
            },
            placeholderSymbol: "tag",
            cardAccessibilityHint: L10n.string("Opens this genre's songs"),
            onOpen: { name in
                self.library.lastVisitedGenre = name
                Task { await self.library.selectDestination(.genre(name)) }
            },
            contextMenu: { _ in EmptyView() },
            scrollOffset: Binding(
                get: { self.library.genreGridScrollOffset },
                set: { self.library.genreGridScrollOffset = $0 }
            )
        )
    }

    /// Sorts `items` by the current ``sortOrder`` via the shared algorithm.
    private func sortedGenres(_ items: [String]) -> [String] {
        CollectionSort.apply(items, byName: self.sortOrder == .genreName, counts: self.trackCounts)
    }

    private var genreList: some View {
        ScrollViewReader { proxy in
            self.genreListContent
                // Re-center the last-visited genre when the list (re)appears, so
                // returning from a genre lands where the user left off (#349).
                .onAppear { self.restoreScrollPosition(proxy) }
                .onChange(of: self.genres) { _, _ in self.restoreScrollPosition(proxy) }
        }
    }

    /// Scrolls the last-visited genre back to the centre of the list.
    private func restoreScrollPosition(_ proxy: ScrollViewProxy) {
        guard let genre = self.library.lastVisitedGenre else { return }
        proxy.scrollTo(genre, anchor: .center)
    }

    private var genreListContent: some View {
        List(self.genres, id: \.self) { genre in
            CollectionListRow(name: genre, symbol: "tag.fill", songCount: self.trackCounts[genre])
                .contentShape(Rectangle())
                .onTapGesture {
                    // Snapshot the visited genre so the list scrolls it back into
                    // view when it's rebuilt on the way back (#349).
                    self.library.lastVisitedGenre = genre
                    Task { await self.library.selectDestination(.genre(genre)) }
                }
                .accessibilityLabel(genre)
                .accessibilityAddTraits(.isButton)
        }
    }
}
