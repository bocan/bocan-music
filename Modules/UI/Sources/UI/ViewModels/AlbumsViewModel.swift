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

    /// Maps artist ID → artist name, loaded alongside albums.
    @Published public private(set) var artistNames: [Int64: String] = [:]

    /// Maps album ID → non-disabled track count, loaded alongside albums.
    @Published public private(set) var trackCounts: [Int64: Int] = [:]

    /// Current grid sort order. Owned here (not via `@AppStorage` in the view)
    /// because album loading is navigation-driven on the view model, so the
    /// persisted preference must be known at load time to sort the first result
    /// without a flash. Persisted in UserDefaults under ``sortOrderKey``.
    @Published public private(set) var sortOrder: AlbumSortOrder

    // MARK: - Internal

    /// UserDefaults key backing ``sortOrder`` (read at init, written by
    /// ``setSortOrder(_:)``).
    public static let sortOrderKey = "albums.sortOrder"

    private let repository: AlbumRepository
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(repository: AlbumRepository) {
        self.repository = repository
        let raw = UserDefaults.standard.string(forKey: Self.sortOrderKey)
        self.sortOrder = raw.flatMap(AlbumSortOrder.init(rawValue:)) ?? .albumName
    }

    // MARK: - Public API

    /// Loads all albums sorted alphabetically.
    public func load() async {
        self.isLoading = true
        self.log.debug("albums.load.start", [:])
        do {
            async let albumsTask = self.repository.fetchAll()
            async let artistNamesTask = self.repository.fetchArtistNameMap()
            async let trackCountsTask = self.repository.fetchTrackCounts()
            // Await all results before any assignment so SwiftUI coalesces the
            // three @Published writes into one render pass.  Without this,
            // `albums` lands first (year now visible) while `trackCounts` is
            // still [:], causing a flash where year shows but count is missing.
            let albums = try await albumsTask
            let artistNames = await (try? artistNamesTask) ?? [:]
            let trackCounts = await (try? trackCountsTask) ?? [:]
            // artistNames first: sortedAlbums(.albumArtist) reads it.
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
            async let artistNamesTask = self.repository.fetchArtistNameMap()
            async let trackCountsTask = self.repository.fetchTrackCounts()
            let albums = try await albumsTask
            let artistNames = await (try? artistNamesTask) ?? [:]
            let trackCounts = await (try? trackCountsTask) ?? [:]
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

    /// Shared body for the filtered destination loads: fetch albums via `fetch`,
    /// plus the artist-name and track-count maps the cells need, then assign.
    private func loadFiltered(_ fetch: @Sendable () async throws -> [Album]) async {
        self.isLoading = true
        do {
            async let artistNamesTask = self.repository.fetchArtistNameMap()
            async let trackCountsTask = self.repository.fetchTrackCounts()
            let albums = try await fetch()
            let artistNames = await (try? artistNamesTask) ?? [:]
            let trackCounts = await (try? trackCountsTask) ?? [:]
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
        UserDefaults.standard.set(order.rawValue, forKey: Self.sortOrderKey)
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
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }

        case .yearNewest:
            items.sorted { lhs, rhs in
                let lyear = lhs.year ?? Int.min
                let ryear = rhs.year ?? Int.min
                if lyear != ryear { return lyear > ryear }
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

    /// Localized label shown in the grid's sort menu.
    public var displayName: String {
        switch self {
        case .albumName:
            L10n.string("Album Name")

        case .albumArtist:
            L10n.string("Album Artist")

        case .yearNewest:
            L10n.string("Year (Newest First)")
        }
    }
}
