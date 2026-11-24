import Foundation
import Observability
import Persistence

// MARK: - AlbumsViewModel

/// Manages the sorted list of albums shown in `AlbumsGridView`.
@MainActor
public final class AlbumsViewModel: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var albums: [Album] = []
    @Published public private(set) var isLoading = false
    @Published public var selectedAlbumID: Int64?

    /// Album-grid vertical scroll offset, snapshotted when navigating into an
    /// album so the grid can restore it when it's rebuilt on return (#349). Plain
    /// `var`, not `@Published`: it must not trigger a re-render.
    public var gridScrollOffset: Double = 0

    /// Where the user was in the full gallery when the current search began,
    /// so clearing the query lands back there (#399). Lives here rather than
    /// in view `@State` so it survives a drill-in/back round trip mid-search.
    /// Plain `var` for the same no-re-render reason as `gridScrollOffset`.
    public var preSearchScrollOffset: Double?

    /// Maps artist ID → artist name, loaded alongside albums.
    @Published public private(set) var artistNames: [Int64: String] = [:]

    /// Maps album ID → non-disabled track count, loaded alongside albums.
    @Published public private(set) var trackCounts: [Int64: Int] = [:]

    /// Current grid sort order. Owned here (not via `@AppStorage` in the view)
    /// because album loading is navigation-driven on the view model, so the
    /// persisted preference must be known at load time to sort the first result
    /// without a flash. Persisted in UserDefaults under the key given at init.
    @Published public private(set) var sortOrder: AlbumSortOrder

    /// Album ID to the newest `added_at` among its songs, loaded with the
    /// albums. Read only by the `.dateAdded` sort, so it is not published.
    private var latestAddedAt: [Int64: Int64] = [:]

    // MARK: - Internal

    /// The main Albums grid's sort key, also used by the genre and composer
    /// album grids.
    public static let sortOrderKey = "albums.sortOrder"
    /// Recently Added's album grid remembers its own sort, newest first by
    /// default, so choosing one never re-sorts the main Albums grid (#700).
    public static let recentlyAddedSortOrderKey = "recentlyAdded.albums.sortOrder"

    /// UserDefaults key backing ``sortOrder`` (read at init, written by
    /// ``setSortOrder(_:)``).
    private let sortOrderStorageKey: String
    private let repository: AlbumRepository
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(
        repository: AlbumRepository,
        sortOrderKey: String = AlbumsViewModel.sortOrderKey,
        defaultSortOrder: AlbumSortOrder = .albumName
    ) {
        self.repository = repository
        self.sortOrderStorageKey = sortOrderKey
        let raw = UserDefaults.standard.string(forKey: sortOrderKey)
        self.sortOrder = raw.flatMap(AlbumSortOrder.init(rawValue:)) ?? defaultSortOrder
    }

    // MARK: - Public API

    /// Loads all albums sorted alphabetically.
    public func load() async {
        self.isLoading = true
        self.log.debug("albums.load.start", [:])
        do {
            async let albumsTask = self.repository.fetchAll()
            async let artistNamesTask = self.artistNameMap(op: "load")
            async let trackCountsTask = self.trackCountMap(op: "load")
            async let latestAddedTask = self.latestAddedMap(op: "load")
            // Await all results before any assignment so SwiftUI coalesces the
            // three @Published writes into one render pass.  Without this,
            // `albums` lands first (year now visible) while `trackCounts` is
            // still [:], causing a flash where year shows but count is missing.
            let albums = try await albumsTask
            let artistNames = await artistNamesTask
            let trackCounts = await trackCountsTask
            // artistNames and latestAddedAt first: sortedAlbums reads them.
            self.latestAddedAt = await latestAddedTask
            self.artistNames = artistNames
            self.trackCounts = trackCounts
            self.albums = self.sortedAlbums(albums)
            self.log.debug("albums.load.end", ["count": self.albums.count])
        } catch {
            self.log.error("albums.load.failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }

    /// Loads albums for a specific artist.
    public func load(albumArtistID: Int64) async {
        self.isLoading = true
        do {
            async let albumsTask = self.repository.fetchAll(albumArtistID: albumArtistID)
            async let artistNamesTask = self.artistNameMap(op: "load(albumArtistID:)")
            async let trackCountsTask = self.trackCountMap(op: "load(albumArtistID:)")
            let albums = try await albumsTask
            let artistNames = await artistNamesTask
            let trackCounts = await trackCountsTask
            self.albums = albums
            self.artistNames = artistNames
            self.trackCounts = trackCounts
        } catch {
            self.log.error("albums.load(artistID).failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }

    /// Loads the albums that contain at least one non-disabled track in `genre`.
    /// Used by the genre destination's Albums mode; mirrors ``load(albumArtistID:)``.
    public func load(genre: String) async {
        await self.loadFiltered { try await self.repository.fetchAll(genre: genre) }
    }

    /// Loads the albums that contain at least one non-disabled track by `composer`.
    public func load(composer: String) async {
        await self.loadFiltered { try await self.repository.fetchAll(composer: composer) }
    }

    /// Loads the albums with a song added in the last `days` days: Recently
    /// Added's Albums mode (#700). Same window as the Songs mode.
    public func load(addedWithinDays days: Int) async {
        await self.loadFiltered { try await self.repository.fetchRecentlyAdded(days: days) }
    }

    /// The artist-name map the grid cells need, recovered to an empty map when
    /// the read fails: the grid then shows rows without artist names, which is
    /// the right recovery but must not be silent (#491).
    ///
    /// `nonisolated` so the `async let` callers still fetch off the main actor
    /// instead of hopping back here and serialising the three reads.
    private nonisolated func artistNameMap(op: String) async -> [Int64: String] {
        do {
            return try await self.repository.fetchArtistNameMap()
        } catch {
            self.log.warning("albums.artistNames.failed", ["op": op, "error": String(reflecting: error)])
            return [:]
        }
    }

    /// The per-album track counts, recovered to an empty map on a read failure
    /// so the grid keeps its rows and loses only the counts. See
    /// ``artistNameMap(op:)`` for why this is `nonisolated`.
    private nonisolated func trackCountMap(op: String) async -> [Int64: Int] {
        do {
            return try await self.repository.fetchTrackCounts()
        } catch {
            self.log.warning("albums.trackCounts.failed", ["op": op, "error": String(reflecting: error)])
            return [:]
        }
    }

    /// Each album's newest song date, for the `.dateAdded` sort. Recovered to
    /// an empty map on a read failure: that sort then falls back to title
    /// order. See ``artistNameMap(op:)`` for why this is `nonisolated`.
    private nonisolated func latestAddedMap(op: String) async -> [Int64: Int64] {
        do {
            return try await self.repository.fetchLatestAddedAt()
        } catch {
            self.log.warning("albums.latestAdded.failed", ["op": op, "error": String(reflecting: error)])
            return [:]
        }
    }

    /// Shared body for the filtered destination loads: fetch albums via `fetch`,
    /// plus the artist-name and track-count maps the cells need, then assign.
    private func loadFiltered(_ fetch: @Sendable () async throws -> [Album]) async {
        self.isLoading = true
        do {
            async let artistNamesTask = self.artistNameMap(op: "loadFiltered")
            async let trackCountsTask = self.trackCountMap(op: "loadFiltered")
            async let latestAddedTask = self.latestAddedMap(op: "loadFiltered")
            let albums = try await fetch()
            let artistNames = await artistNamesTask
            let trackCounts = await trackCountsTask
            self.latestAddedAt = await latestAddedTask
            self.artistNames = artistNames
            self.trackCounts = trackCounts
            self.albums = self.sortedAlbums(albums)
        } catch {
            self.log.error("albums.loadFiltered.failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }

    /// Replaces the album list with a pre-fetched result (search results).
    public func setAlbums(_ items: [Album]) {
        self.albums = self.sortedAlbums(items)
    }

    /// Applies a mutation to a single album in the in-memory list without reloading
    /// the whole array.  Avoids resetting the detail-column navigation stack.
    public func patch(albumID: Int64, _ mutation: (inout Album) -> Void) {
        guard let idx = self.albums.firstIndex(where: { $0.id == albumID }) else { return }
        mutation(&self.albums[idx])
    }

    /// FTS search: replaces the visible list with albums matching `query`.
    public func search(query: String) async {
        self.isLoading = true
        do {
            self.albums = try await self.sortedAlbums(self.repository.search(query: query))
        } catch {
            self.log.error("albums.search.failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }

    /// Changes the grid sort order, persists it, and re-sorts in place (no refetch).
    public func setSortOrder(_ order: AlbumSortOrder) {
        guard order != self.sortOrder else { return }
        self.sortOrder = order
        UserDefaults.standard.set(order.rawValue, forKey: self.sortOrderStorageKey)
        self.albums = self.sortedAlbums(self.albums)
    }

    /// Sorts `items` by the current ``sortOrder``, resolving album-artist names
    /// from ``artistNames``. Uses `localizedStandardCompare` so numbers and
    /// diacritics order naturally.
    private func sortedAlbums(_ items: [Album]) -> [Album] {
        switch self.sortOrder {
        case .albumName:
            items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        case .albumArtist:
            items.sorted { lhs, rhs in
                let lname = lhs.albumArtistID.flatMap { self.artistNames[$0] } ?? ""
                let rname = rhs.albumArtistID.flatMap { self.artistNames[$0] } ?? ""
                let cmp = lname.localizedStandardCompare(rname)
                if cmp != .orderedSame {
                    return cmp == .orderedAscending
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }

        case .yearNewest:
            items.sorted { lhs, rhs in
                let lyear = lhs.year ?? Int.min
                let ryear = rhs.year ?? Int.min
                if lyear != ryear {
                    return lyear > ryear
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }

        case .dateAdded:
            items.sorted { lhs, rhs in
                let ladded = lhs.id.flatMap { self.latestAddedAt[$0] } ?? Int64.min
                let radded = rhs.id.flatMap { self.latestAddedAt[$0] } ?? Int64.min
                if ladded != radded {
                    return ladded > radded
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }
}

// MARK: - AlbumSortOrder

/// Sort order for the main Albums grid (issue #349).
public enum AlbumSortOrder: String, CaseIterable, Sendable {
    /// Album title, A->Z (the historical default).
    case albumName
    /// Album artist A->Z, then album title within each artist.
    case albumArtist
    /// Release year, newest first, then title.
    case yearNewest
    /// The newest song's date added, newest first, then title (#700).
    case dateAdded

    /// Localized label shown in the grid's sort menu.
    public var displayName: String {
        switch self {
        case .albumName:
            L10n.string("Album Name")

        case .albumArtist:
            L10n.string("Album Artist")

        case .yearNewest:
            L10n.string("Year (Newest First)")

        case .dateAdded:
            L10n.string("Date Added (Newest First)")
        }
    }
}
