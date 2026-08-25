import Persistence
import SwiftUI

// MARK: - ComposersView

/// Lists all composers in the library.  Selecting one pushes a track list.
public struct ComposersView: View {
    public var library: LibraryViewModel
    /// The toolbar search query, passed as a value so a keystroke re-renders
    /// this view without it observing the whole library view model.
    public var searchQuery: String

    @State private var composers: [String] = []
    @State private var trackCounts: [String: Int] = [:]
    /// Card data (counts + cover paths) keyed by composer, for grid mode. Loaded
    /// alongside the list fetch so switching modes never refetches.
    @State private var cardData: [String: CollectionCardData] = [:]
    @State private var isLoading = true
    /// Persisted list sort order; defaults to composer name.
    @AppStorage("composers.sortOrder") private var sortOrder: ComposerSortOrder = .composerName
    /// Persisted List vs Grid mode; defaults to List so the view is unchanged
    /// until the user opts in (ADR-073). String-backed so the "View as" menu's
    /// writes reliably redraw this listing (ADR-074).
    @CollectionViewModeStorage("composers.viewMode") private var viewMode

    public init(library: LibraryViewModel, searchQuery: String) {
        self.library = library
        self.searchQuery = searchQuery
    }

    /// The composers surviving the active search filter, in display order.
    private var visibleComposers: [String] {
        let query = self.searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return self.composers }
        return self.composers.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    public var body: some View {
        Group {
            if self.isLoading {
                LoadingState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.composers.isEmpty {
                EmptyState(
                    symbol: "music.note.list",
                    title: L10n.string("No Composers"),
                    message: L10n.string("No composer tags found in your library.")
                )
            } else if self.visibleComposers.isEmpty {
                let query = self.searchQuery.trimmingCharacters(in: .whitespaces)
                EmptyState(
                    symbol: "magnifyingglass",
                    title: L10n.string("No Results"),
                    message: L10n.string("No composers match \u{201C}\(query)\u{201D}.")
                )
            } else if self.viewMode == .grid {
                self.composerGrid
            } else {
                self.composerList
            }
        }
        .navigationTitle(L10n.string("Composers"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CollectionViewModeToggle(mode: self.$viewMode)
            }
            ToolbarItem(placement: .primaryAction) {
                SortMenu(selection: self.$sortOrder, help: L10n.string("Choose how composers are sorted"))
            }
        }
        .task {
            let trackRepo = TrackRepository(database: self.library.database)
            let albumRepo = AlbumRepository(database: self.library.database)
            async let composersFetch = try? trackRepo.allComposers()
            async let countsFetch = try? trackRepo.composerTrackCounts()
            async let cardsFetch = try? albumRepo.fetchComposerCards()
            let allComposers = await composersFetch ?? []
            self.trackCounts = await countsFetch ?? [:]
            self.cardData = await Dictionary(uniqueKeysWithValues: (cardsFetch ?? []).map { ($0.name, $0) })
            self.composers = self.sortedComposers(allComposers)
            self.isLoading = false
        }
        // Re-sort in place when the user changes the order (no refetch).
        .onChange(of: self.sortOrder) { _, _ in self.composers = self.sortedComposers(self.composers) }
    }

    /// Grid of composer cards, ordered by the same sorted `composers` array the
    /// list uses so the SortMenu reorders both modes identically.
    private var composerGrid: some View {
        CollectionCardGrid(
            models: self.visibleComposers.map { name in
                let data = self.cardData[name]
                return CollectionCardModel(
                    id: name,
                    title: name,
                    albumCount: data?.albumCount ?? 0,
                    songCount: data?.songCount ?? self.trackCounts[name] ?? 0,
                    coverArtPaths: data?.coverArtPaths ?? []
                )
            },
            placeholderSymbol: "music.quarternote.3",
            cardAccessibilityHint: L10n.string("Opens this composer's songs"),
            onOpen: { name in
                self.library.lastVisitedComposer = name
                Task { await self.library.selectDestination(.composer(name)) }
            },
            contextMenu: { _ in EmptyView() },
            scrollOffset: Binding(
                get: { self.library.composerGridScrollOffset },
                set: { self.library.composerGridScrollOffset = $0 }
            ),
            searchQuery: self.searchQuery
        )
    }

    /// Sorts `items` by the current ``sortOrder`` via the shared algorithm.
    private func sortedComposers(_ items: [String]) -> [String] {
        CollectionSort.apply(items, byName: self.sortOrder == .composerName, counts: self.trackCounts)
    }

    private var composerList: some View {
        ScrollViewReader { proxy in
            self.composerListContent
                // Re-center the last-visited composer when the list (re)appears,
                // so returning from a composer lands where the user left off (#349).
                .onAppear { self.restoreScrollPosition(proxy) }
                .onChange(of: self.composers) { _, _ in self.restoreScrollPosition(proxy) }
        }
    }

    /// Scrolls the last-visited composer back to the centre of the list.
    private func restoreScrollPosition(_ proxy: ScrollViewProxy) {
        guard let composer = self.library.lastVisitedComposer else { return }
        proxy.scrollTo(composer, anchor: .center)
    }

    private var composerListContent: some View {
        List(self.visibleComposers, id: \.self) { composer in
            CollectionListRow(name: composer, symbol: "music.note.list", songCount: self.trackCounts[composer])
                .contentShape(Rectangle())
                .onTapGesture {
                    // Snapshot the visited composer so the list scrolls it back
                    // into view when it's rebuilt on the way back (#349).
                    self.library.lastVisitedComposer = composer
                    Task { await self.library.selectDestination(.composer(composer)) }
                }
                .accessibilityLabel(composer)
                .accessibilityAddTraits(.isButton)
        }
    }
}
