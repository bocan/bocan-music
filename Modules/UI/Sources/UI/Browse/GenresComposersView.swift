import Persistence
import SwiftUI

// MARK: - GenresView

/// Lists all genres in the library.  Selecting a genre pushes a track list.
public struct GenresView: View {
    public var library: LibraryViewModel

    @State private var genres: [String] = []
    @State private var trackCounts: [String: Int] = [:]
    @State private var isLoading = true
    /// Persisted list sort order; defaults to song count (the historical order).
    @AppStorage("genres.sortOrder") private var sortOrder: GenreSortOrder = .songCount

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
            } else {
                self.genreList
            }
        }
        .navigationTitle(L10n.string("Genres"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SortMenu(selection: self.$sortOrder, help: L10n.string("Choose how genres are sorted"))
            }
        }
        .task {
            let repo = TrackRepository(database: self.library.database)
            async let genresFetch = try? repo.allGenres()
            async let countsFetch = try? repo.genreTrackCounts()
            let allGenres = await genresFetch ?? []
            self.trackCounts = await countsFetch ?? [:]
            self.genres = self.sortedGenres(allGenres)
            self.isLoading = false
        }
        // Re-sort in place when the user changes the order (no refetch).
        .onChange(of: self.sortOrder) { _, _ in self.genres = self.sortedGenres(self.genres) }
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

// MARK: - ComposersView

/// Lists all composers in the library.  Selecting one pushes a track list.
public struct ComposersView: View {
    public var library: LibraryViewModel

    @State private var composers: [String] = []
    @State private var trackCounts: [String: Int] = [:]
    @State private var isLoading = true
    /// Persisted list sort order; defaults to composer name.
    @AppStorage("composers.sortOrder") private var sortOrder: ComposerSortOrder = .composerName

    public init(library: LibraryViewModel) {
        self.library = library
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
            } else {
                self.composerList
            }
        }
        .navigationTitle(L10n.string("Composers"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SortMenu(selection: self.$sortOrder, help: L10n.string("Choose how composers are sorted"))
            }
        }
        .task {
            let repo = TrackRepository(database: self.library.database)
            async let composersFetch = try? repo.allComposers()
            async let countsFetch = try? repo.composerTrackCounts()
            let allComposers = await composersFetch ?? []
            self.trackCounts = await countsFetch ?? [:]
            self.composers = self.sortedComposers(allComposers)
            self.isLoading = false
        }
        // Re-sort in place when the user changes the order (no refetch).
        .onChange(of: self.sortOrder) { _, _ in self.composers = self.sortedComposers(self.composers) }
    }

    /// Sorts `items` by the current ``sortOrder``. Song count falls back to
    /// composer name as a secondary key; `localizedStandardCompare` orders names
    /// naturally.
    private func sortedComposers(_ items: [String]) -> [String] {
        switch self.sortOrder {
        case .composerName:
            items.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        case .songCount:
            items.sorted { lhs, rhs in
                let lcount = self.trackCounts[lhs] ?? 0
                let rcount = self.trackCounts[rhs] ?? 0
                if lcount != rcount { return lcount > rcount }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }
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
        List(self.composers, id: \.self) { composer in
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "music.note.list")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(composer)
                        .font(Typography.body)
                        .foregroundStyle(Color.textPrimary)

                    if let count = self.trackCounts[composer], count > 0 {
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
                // Snapshot the visited composer so the list scrolls it back into
                // view when it's rebuilt on the way back (#349).
                self.library.lastVisitedComposer = composer
                Task { await self.library.selectDestination(.composer(composer)) }
            }
            .accessibilityLabel(composer)
            .accessibilityAddTraits(.isButton)
        }
    }
}

// MARK: - GenreSortOrder

/// Sort order for the Genres list.
enum GenreSortOrder: String, CaseIterable, SortMenuOption {
    /// Song count, most first, then genre name (the historical default).
    case songCount
    /// Genre name, A->Z.
    case genreName

    /// Localized label shown in the list's sort menu.
    var displayName: String {
        switch self {
        case .songCount:
            L10n.string("Song Count")

        case .genreName:
            L10n.string("Genre Name")
        }
    }
}

// MARK: - ComposerSortOrder

/// Sort order for the Composers list.
enum ComposerSortOrder: String, CaseIterable, SortMenuOption {
    /// Composer name, A->Z (the default).
    case composerName
    /// Song count, most first, then composer name.
    case songCount

    /// Localized label shown in the list's sort menu.
    var displayName: String {
        switch self {
        case .composerName:
            L10n.string("Composer Name")

        case .songCount:
            L10n.string("Song Count")
        }
    }
}
