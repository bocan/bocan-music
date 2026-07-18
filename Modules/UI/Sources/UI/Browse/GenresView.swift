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
    /// until the user opts in (phase 23-2).
    @AppStorage("genres.viewMode") private var viewMode: CollectionViewMode = .list

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
                self.viewModePicker
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

    /// Segmented List / Grid toggle placed next to the sort menu.
    private var viewModePicker: some View {
        Picker(L10n.string("Choose how this view is displayed"), selection: self.$viewMode) {
            Image(systemName: "list.bullet")
                .accessibilityLabel(L10n.string("View as list"))
                .tag(CollectionViewMode.list)
            Image(systemName: "square.grid.2x2")
                .accessibilityLabel(L10n.string("View as grid"))
                .tag(CollectionViewMode.grid)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help(L10n.string("Choose how this view is displayed"))
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

    /// Sorts `items` by the current ``sortOrder``. Song count falls back to genre
    /// name as a secondary key; `localizedStandardCompare` orders names naturally.
    private func sortedGenres(_ items: [String]) -> [String] {
        switch self.sortOrder {
        case .songCount:
            items.sorted { lhs, rhs in
                let lcount = self.trackCounts[lhs] ?? 0
                let rcount = self.trackCounts[rhs] ?? 0
                if lcount != rcount { return lcount > rcount }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }

        case .genreName:
            items.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
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
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "tag.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(genre)
                        .font(Typography.body)
                        .foregroundStyle(Color.textPrimary)

                    if let count = self.trackCounts[genre], count > 0 {
                        Text(localized: "\(count) songs")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .accessibilityHidden(true)
            }
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
