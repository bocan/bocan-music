import Foundation
import Observability
import Persistence

// MARK: - ArtistsViewModel

/// Manages the sorted list of artists shown in `ArtistsView`.
@MainActor
public final class ArtistsViewModel: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var artists: [Artist] = []
    @Published public private(set) var albumCounts: [Int64: Int] = [:]
    @Published public private(set) var trackCounts: [Int64: Int] = [:]
    @Published public private(set) var isLoading = false
    @Published public var selectedArtistID: Int64?

    /// Current list sort order. Owned here (not via `@AppStorage` in the view)
    /// so the persisted preference is known at load time and the first result is
    /// sorted without a flash. Persisted in UserDefaults under ``sortOrderKey``.
    @Published public private(set) var sortOrder: ArtistSortOrder

    /// The artist last navigated into, snapshotted when opening an artist so the
    /// list can scroll it back into view when the list is rebuilt on return
    /// (mirrors the album-grid scroll restore, #349). Plain `var`, not
    /// `@Published`: it must not trigger a re-render.
    public var lastVisitedArtistID: Int64?

    // MARK: - Internal

    /// UserDefaults key backing ``sortOrder`` (read at init, written by
    /// ``setSortOrder(_:)``).
    public static let sortOrderKey = "artists.sortOrder"

    private let repository: ArtistRepository
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(repository: ArtistRepository) {
        self.repository = repository
        let raw = UserDefaults.standard.string(forKey: Self.sortOrderKey)
        self.sortOrder = raw.flatMap(ArtistSortOrder.init(rawValue:)) ?? .artistName
    }

    // MARK: - Public API

    /// Loads all artists, sorted by the current ``sortOrder``.
    public func load() async {
        self.isLoading = true
        self.log.debug("artists.load.start", [:])
        do {
            async let artistsFetch = self.repository.fetchAll()
            async let albumCountsFetch = self.repository.fetchAlbumCounts()
            async let trackCountsFetch = self.repository.fetchTrackCounts()
            let fetched = try await artistsFetch
            // Counts first: the count-based sorts read them.
            self.albumCounts = await (try? albumCountsFetch) ?? [:]
            self.trackCounts = await (try? trackCountsFetch) ?? [:]
            self.artists = self.sortedArtists(fetched)
            self.log.debug("artists.load.end", ["count": self.artists.count])
        } catch {
            self.log.error("artists.load.failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }

    /// Replaces the artist list with a pre-fetched result (search results).
    public func setArtists(_ items: [Artist]) {
        self.artists = self.sortedArtists(items)
    }

    /// FTS search: replaces the visible list with artists matching `query`.
    public func search(query: String) async {
        self.isLoading = true
        do {
            self.artists = try await self.sortedArtists(self.repository.search(query: query))
        } catch {
            self.log.error("artists.search.failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }

    /// Changes the list sort order, persists it, and re-sorts in place (no refetch).
    public func setSortOrder(_ order: ArtistSortOrder) {
        guard order != self.sortOrder else { return }
        self.sortOrder = order
        UserDefaults.standard.set(order.rawValue, forKey: Self.sortOrderKey)
        self.artists = self.sortedArtists(self.artists)
    }

    /// Sorts `items` by the current ``sortOrder``. The count-based orders fall
    /// back to artist name as a secondary key. Uses `localizedStandardCompare`
    /// so numbers and diacritics order naturally.
    private func sortedArtists(_ items: [Artist]) -> [Artist] {
        switch self.sortOrder {
        case .artistName:
            items.sorted { Self.nameKey($0).localizedStandardCompare(Self.nameKey($1)) == .orderedAscending }

        case .albumCount:
            items.sorted { lhs, rhs in
                let lcount = lhs.id.flatMap { self.albumCounts[$0] } ?? 0
                let rcount = rhs.id.flatMap { self.albumCounts[$0] } ?? 0
                if lcount != rcount { return lcount > rcount }
                return Self.nameKey(lhs).localizedStandardCompare(Self.nameKey(rhs)) == .orderedAscending
            }

        case .songCount:
            items.sorted { lhs, rhs in
                let lcount = lhs.id.flatMap { self.trackCounts[$0] } ?? 0
                let rcount = rhs.id.flatMap { self.trackCounts[$0] } ?? 0
                if lcount != rcount { return lcount > rcount }
                return Self.nameKey(lhs).localizedStandardCompare(Self.nameKey(rhs)) == .orderedAscending
            }
        }
    }

    /// Sort key for an artist: the sort-normalised name when present, else the
    /// display name (matches the database's `sort_name`, `name` ordering).
    private static func nameKey(_ artist: Artist) -> String {
        artist.sortName ?? artist.name
    }
}

// MARK: - ArtistSortOrder

/// Sort order for the Artists list.
public enum ArtistSortOrder: String, CaseIterable, Sendable, SortMenuOption {
    /// Artist name, A->Z (the historical default).
    case artistName
    /// Album count, most first, then artist name.
    case albumCount
    /// Song count, most first, then artist name.
    case songCount

    /// Localized label shown in the list's sort menu.
    public var displayName: String {
        switch self {
        case .artistName:
            L10n.string("Artist Name")

        case .albumCount:
            L10n.string("Album Count")

        case .songCount:
            L10n.string("Song Count")
        }
    }
}
