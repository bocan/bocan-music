import Foundation
import Observability
import Persistence

// MARK: - Track sort support

/// Codable column identifier used to persist table sort state.
///
/// `KeyPathComparator<Track>` is not `Codable`, so we store this enum
/// and reconstruct the comparator on load. See gotchas in phase-04.
public enum TrackSortColumn: String, Codable, Sendable, CaseIterable {
    case title
    case artist
    case album
    case year
    case genre
    case duration
    case playCount
    case rating
    case addedAt
    case trackNumber

    public var displayName: String {
        switch self {
        case .title:
            "Title"

        case .artist:
            "Artist"

        case .album:
            "Album"

        case .year:
            "Year"

        case .genre:
            "Genre"

        case .duration:
            "Time"

        case .playCount:
            "Plays"

        case .rating:
            "Rating"

        case .addedAt:
            "Date Added"

        case .trackNumber:
            "#"
        }
    }
}

// MARK: - TracksViewModel

/// Manages the sorted, filtered list of tracks shown in `TracksView`.
///
/// Owned by `LibraryViewModel` and injected into `TracksView` as an
/// `@ObservedObject`.  All mutation happens on `@MainActor`.
///
/// ## Sorting
///
/// Sort state is a single source of truth: `sortOrder`, an array of
/// `KeyPathComparator<TrackRow>` bound directly to `Table(sortOrder:)`.
/// When it changes — whether by a column-header click or programmatic
/// `setSort(column:ascending:)` — `rows` is resorted in place.  Nothing
/// else re-sorts the array behind the Table's back.
@MainActor
public final class TracksViewModel: ObservableObject {
    // MARK: - Published state

    /// Decorated, already-sorted rows rendered by `Table`.
    @Published public private(set) var rows: [TrackRow] = []
    @Published public private(set) var isLoading = false
    @Published public var selection: Set<Track.ID> = []

    /// Full stack of active comparators.  Owned by `TracksView` as
    /// `@State` and pushed in via `applySort(_:)` — keeping the Table's
    /// binding writes out of `@Published` is what prevents the
    /// SwiftUI-reentrant update cycle that otherwise runs CPU to 100%
    /// and allocates ~1 GB every few seconds.
    public private(set) var sortOrder: [KeyPathComparator<TrackRow>] = TracksViewModel.defaultSortOrder

    /// Free-text filter (operates client-side for in-memory arrays).
    @Published public var filterText = ""

    /// Maps `artistID → artist name` for column display.  Refreshed on every load.
    @Published public private(set) var artistNames: [Int64: String] = [:]

    /// Maps `albumID → album title` for column display.  Refreshed on every load.
    @Published public private(set) var albumNames: [Int64: String] = [:]

    // MARK: - Computed back-compat accessors

    /// The raw tracks, in their current display order.  Preserved for
    /// call sites (playback, context menus, tests) that don't need the
    /// decorated row values.
    public var tracks: [Track] {
        self.rows.map(\.track)
    }

    /// The primary sort column, derived from `sortOrder.first`.  Used
    /// by `LibraryViewModel` when serialising `UIStateV1`.
    public var sortColumn: TrackSortColumn {
        guard let first = sortOrder.first else { return .addedAt }
        return Self.column(for: first) ?? .addedAt
    }

    /// `true` when the primary comparator sorts ascending.
    public var sortAscending: Bool {
        self.sortOrder.first?.order == .forward
    }

    /// `true` while the default sort (Date Added, descending) is active.
    /// The toolbar uses this to dim the "Reset Sort" affordance.
    public var isDefaultSortOrder: Bool {
        self.sortOrder == Self.defaultSortOrder
    }

    // MARK: - Default sort

    /// Default sort: most-recently added first.  Matches the order rows
    /// naturally arrive in from `TrackRepository.fetchAll()` and so
    /// serves as a sensible "revert to library order" option.
    public static let defaultSortOrder: [KeyPathComparator<TrackRow>] = [
        KeyPathComparator(\TrackRow.addedAt, order: .reverse),
    ]

    // MARK: - Internal

    private let repository: TrackRepository
    private let artistRepository: ArtistRepository
    private let albumRepository: AlbumRepository
    private var allRows: [TrackRow] = []
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(
        repository: TrackRepository,
        artistRepository: ArtistRepository,
        albumRepository: AlbumRepository
    ) {
        self.repository = repository
        self.artistRepository = artistRepository
        self.albumRepository = albumRepository
    }

    // MARK: - Public API

    /// (Re)loads all tracks from the database and applies current sort/filter.
    public func load() async {
        self.isLoading = true
        self.log.debug("tracks.load.start", [:])
        do {
            let fetched = try await self.repository.fetchAll()
            await self.refreshNameLookups()
            self.rebuildAllRows(from: fetched)
            self.applyFilter()
            self.log.debug("tracks.load.end", ["count": fetched.count])
        } catch {
            self.log.error("tracks.load.failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }

    /// Loads tracks for a specific album.
    public func load(albumID: Int64) async {
        self.isLoading = true
        do {
            let fetched = try await self.repository.fetchAll(albumID: albumID)
            await self.refreshNameLookups()
            self.rebuildAllRows(from: fetched)
            self.applyFilter()
        } catch {
            self.log.error("tracks.load(albumID).failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }

    /// Loads tracks for a specific artist.
    public func load(artistID: Int64) async {
        self.isLoading = true
        do {
            let fetched = try await self.repository.fetchAll(artistID: artistID)
            await self.refreshNameLookups()
            self.rebuildAllRows(from: fetched)
            self.applyFilter()
        } catch {
            self.log.error("tracks.load(artistID).failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }

    /// Loads tracks for a specific genre.
    public func load(genre: String) async {
        self.isLoading = true
        do {
            let fetched = try await self.repository.fetchAll(genre: genre)
            await self.refreshNameLookups()
            self.rebuildAllRows(from: fetched)
            self.applyFilter()
        } catch {
            self.log.error("tracks.load(genre).failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }

    /// Loads tracks for a specific composer.
    public func load(composer: String) async {
        self.isLoading = true
        do {
            let fetched = try await self.repository.fetchAll(composer: composer)
            await self.refreshNameLookups()
            self.rebuildAllRows(from: fetched)
            self.applyFilter()
        } catch {
            self.log.error("tracks.load(composer).failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }

    /// Sets a pre-fetched track list directly (used by smart folders / search results).
    public func setTracks(_ items: [Track]) {
        self.rebuildAllRows(from: items)
        self.applyFilter()
    }

    /// FTS search: replaces the visible list with results matching `query`.
    public func search(query: String) async {
        self.isLoading = true
        do {
            let results = try await self.repository.search(query: query)
            await self.refreshNameLookups()
            self.setTracks(results)
        } catch {
            self.log.error("tracks.search.failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }

    /// Programmatic shim that maps a `(column, ascending)` pair onto
    /// `sortOrder`.  Kept so persisted `UIStateV1` values restore cleanly
    /// and the existing view-model tests remain green.
    public func setSort(column: TrackSortColumn, ascending: Bool) {
        let order: SortOrder = ascending ? .forward : .reverse
        self.applySort([Self.comparator(for: column, order: order)])
    }

    /// Reverts to the default (Date Added, descending) sort order.
    public func resetSort() {
        self.applySort(Self.defaultSortOrder)
    }

    /// Called by `TracksView` whenever the Table's `@State sortOrder`
    /// changes.  Deduplicates identical writes and resorts `rows` in
    /// place.  `objectWillChange` only fires for the `rows` reassignment,
    /// never for `sortOrder` — so Table's per-frame binding writes
    /// cannot trigger a SwiftUI update cycle.
    public func applySort(_ order: [KeyPathComparator<TrackRow>]) {
        guard order != self.sortOrder else { return }
        self.sortOrder = order
        self.rows.sort(using: order)
    }

    // MARK: - Private

    private func refreshNameLookups() async {
        let artists = await (try? self.artistRepository.fetchAll()) ?? []
        let albums = await (try? self.albumRepository.fetchAll()) ?? []
        self.artistNames = Dictionary(
            uniqueKeysWithValues: artists.compactMap { artist in
                artist.id.map { id in (id, artist.name) }
            }
        )
        self.albumNames = Dictionary(
            uniqueKeysWithValues: albums.compactMap { album in
                album.id.map { id in (id, album.title) }
            }
        )
    }

    /// Rebuilds the unfiltered `allRows` backing array from `source`
    /// using the current artist/album name lookups.
    private func rebuildAllRows(from source: [Track]) {
        let artists = self.artistNames
        let albums = self.albumNames
        self.allRows = source.map { track in
            TrackRow(
                track: track,
                artistName: track.artistID.flatMap { artists[$0] },
                albumName: track.albumID.flatMap { albums[$0] }
            )
        }
    }

    private func applyFilter() {
        var result = self.allRows
        if !self.filterText.isEmpty {
            let lowered = self.filterText.lowercased()
            result = result.filter { $0.title.lowercased().contains(lowered) }
        }
        result.sort(using: self.sortOrder)
        self.rows = result
    }

    // MARK: - Sort column mapping

    /// Builds the `KeyPathComparator` that matches a persisted
    /// `(column, order)` pair.  Strings use `.localizedStandard` so
    /// "Allman Brothers" sorts before "älfheim" the way users expect.
    private static func comparator(
        for column: TrackSortColumn,
        order: SortOrder
    ) -> KeyPathComparator<TrackRow> {
        switch column {
        case .title:
            KeyPathComparator(\TrackRow.title, comparator: .localizedStandard, order: order)

        case .artist:
            KeyPathComparator(\TrackRow.artistName, comparator: .localizedStandard, order: order)

        case .album:
            KeyPathComparator(\TrackRow.albumName, comparator: .localizedStandard, order: order)

        case .genre:
            KeyPathComparator(\TrackRow.genre, comparator: .localizedStandard, order: order)

        case .year:
            KeyPathComparator(\TrackRow.year, order: order)

        case .duration:
            KeyPathComparator(\TrackRow.duration, order: order)

        case .playCount:
            KeyPathComparator(\TrackRow.playCount, order: order)

        case .rating:
            KeyPathComparator(\TrackRow.rating, order: order)

        case .addedAt:
            KeyPathComparator(\TrackRow.addedAt, order: order)

        case .trackNumber:
            KeyPathComparator(\TrackRow.trackNumber, order: order)
        }
    }

    /// Reverse of `comparator(for:order:)` — recovers the persisted
    /// column identifier from a live comparator so `LibraryViewModel`
    /// can serialise `UIStateV1` without a parallel source of truth.
    private static func column(for comparator: KeyPathComparator<TrackRow>) -> TrackSortColumn? {
        let keyPath = comparator.keyPath
        if keyPath == \TrackRow.title { return .title }
        if keyPath == \TrackRow.artistName { return .artist }
        if keyPath == \TrackRow.albumName { return .album }
        if keyPath == \TrackRow.genre { return .genre }
        if keyPath == \TrackRow.year { return .year }
        if keyPath == \TrackRow.duration { return .duration }
        if keyPath == \TrackRow.playCount { return .playCount }
        if keyPath == \TrackRow.rating { return .rating }
        if keyPath == \TrackRow.addedAt { return .addedAt }
        if keyPath == \TrackRow.trackNumber { return .trackNumber }
        return nil
    }
}
