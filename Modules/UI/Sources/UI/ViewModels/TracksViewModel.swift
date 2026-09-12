import Foundation
import Observability
import Observation
import Persistence

// MARK: - TracksViewModel

/// Manages the sorted, filtered list of tracks shown in `TracksView`.
///
/// Owned by `LibraryViewModel` and injected into `TracksView`. All mutation
/// happens on `@MainActor`.
///
/// ## Sorting
///
/// Sort state has a single source of truth: `sortOrder`, an array of
/// `KeyPathComparator<TrackRow>`. When it changes (column-header click or
/// programmatic `setSort`), `rows` is resorted in place; nothing else re-sorts
/// the array behind the Table's back.
@Observable
@MainActor
public final class TracksViewModel {
    // MARK: - State

    /// Decorated, already-sorted rows rendered by `Table`.
    public private(set) var rows: [TrackRow] = [] {
        didSet { self.rowsVersion &+= 1 }
    }

    /// Moves on every write to `rows`, in-place ones included, via `didSet` so no
    /// path can forget it; `TrackTable` skips its per-row walks while it holds (#450).
    public private(set) var rowsVersion = 0
    /// `true` while a load or search is in flight.
    public private(set) var isLoading = false
    /// The currently selected track IDs.
    public var selection: Set<Track.ID> = []

    /// Full stack of active comparators. Owned by `TracksView` as `@State` and
    /// pushed in via `applySort(_:)`; keeping the Table's binding writes out of
    /// the observation path prevents a SwiftUI-reentrant update cycle that
    /// otherwise pins the CPU and allocates ~1 GB every few seconds.
    public private(set) var sortOrder: [KeyPathComparator<TrackRow>] = TracksViewModel.defaultSortOrder

    /// Free-text filter (operates client-side for in-memory arrays).
    public var filterText = ""

    /// Maps `artistID → artist name` for column display.  Refreshed on every load.
    public private(set) var artistNames: [Int64: String] = [:]

    /// Maps `albumID → album title` for column display.  Refreshed on every load.
    public private(set) var albumNames: [Int64: String] = [:]

    /// Maps `albumID → cover art file-system path` for the art column.  Refreshed on every load.
    private var albumArtPaths: [Int64: String] = [:]

    /// Incremented when a caller wants the table to scroll a row into view;
    /// `TrackTable.updateNSView` reacts with `scrollRowToVisible`. Mutated,
    /// with `scrollTargetTrackID`, by the request functions in
    /// `TracksViewModel+Scrolling.swift`, hence internal(set).
    public internal(set) var scrollRequest = 0

    /// The track a pending scroll request targets; `nil` means now-playing.
    public internal(set) var scrollTargetTrackID: Int64?

    // MARK: - Computed back-compat accessors

    /// The raw tracks in display order, for call sites that don't need the decorated rows.
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

    /// Default sort: artist → album → track number, matching the natural
    /// disc order a user expects when browsing the library.
    public static let defaultSortOrder: [KeyPathComparator<TrackRow>] = [
        KeyPathComparator(\TrackRow.artistName, comparator: .localizedStandard, order: .forward),
        KeyPathComparator(\TrackRow.albumName, comparator: .localizedStandard, order: .forward),
        KeyPathComparator(\TrackRow.trackNumber, order: .forward),
    ]

    // MARK: - Internal

    private let repository: TrackRepository
    private let artistRepository: ArtistRepository
    private let albumRepository: AlbumRepository
    private var allRows: [TrackRow] = []
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    /// Creates a new `TracksViewModel` backed by the given repositories.
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

    /// Selects all currently visible rows.
    public func selectAll() {
        self.selection = Set(self.rows.compactMap(\.id))
    }

    /// Clears the selection.
    public func deselectAll() {
        self.selection = []
    }

    /// (Re)loads all tracks from the database and applies current sort/filter.
    public func load() async {
        let endTimer = Telemetry.timer("tracks.load")
        defer { endTimer() }
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

    /// Loads a specific album, preserving the database disc/track order.
    public func load(albumID: Int64) async {
        self.isLoading = true
        do {
            let fetched = try await self.repository.fetchAll(albumID: albumID)
            await self.refreshNameLookups()
            self.rebuildAllRows(from: fetched)
            // Preserve the disc/track ordering returned by the database.
            if self.filterText.isEmpty {
                self.rows = self.allRows
            } else {
                let lowered = self.filterText.lowercased()
                self.rows = self.allRows.filter { $0.title.lowercased().contains(lowered) }
            }
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

    /// Update the displayed data for specific tracks without reloading the full list.
    ///
    /// Replaces the matching rows in `allRows` and `rows` in-place so the `Table`
    /// keeps its scroll position and selection intact.  Artist/album names are
    /// resolved from the current cached lookup dictionaries — if a name itself
    /// changed it will be corrected on the next full load.
    public func updateRows(for updatedTracks: [Track]) {
        guard !updatedTracks.isEmpty else { return }
        let artists = self.artistNames
        let albums = self.albumNames
        let artPaths = self.albumArtPaths
        let newRowsByID: [Int64: TrackRow] = updatedTracks.reduce(into: [:]) { dict, track in
            guard let id = track.id else { return }
            dict[id] = TrackRow(
                track: track,
                artistName: track.artistID.flatMap { artists[$0] },
                albumName: track.albumID.flatMap { albums[$0] },
                albumCoverArtPath: track.albumID.flatMap { artPaths[$0] }
            )
        }
        // Mutate local copies and assign once: `rows` has a `didSet`, so an
        // in-place `self.rows[i] = ...` inside the loop would copy the whole
        // array and bump `rowsVersion` once per matched row (#453).
        if let allRows = Self.replacing(self.allRows, with: newRowsByID) {
            self.allRows = allRows
        }
        if let rows = Self.replacing(self.rows, with: newRowsByID) {
            self.rows = rows
        }
    }

    /// Returns `rows` with every row whose track id appears in `newRowsByID`
    /// swapped for the new value, or `nil` when no row matched so the caller
    /// can leave the stored array (and its version) untouched.
    private static func replacing(_ rows: [TrackRow], with newRowsByID: [Int64: TrackRow]) -> [TrackRow]? {
        var rows = rows
        var changed = false
        for i in rows.indices {
            if let id = rows[i].track.id, let updated = newRowsByID[id] {
                rows[i] = updated
                changed = true
            }
        }
        return changed ? rows : nil
    }

    /// Sets a pre-fetched track list directly (smart folders / search results).
    /// Pass `preserveOrder: true` when the caller owns the canonical ordering
    /// (e.g. a manual playlist): the list is not re-sorted by the current
    /// comparator, though the text filter still applies.
    public func setTracks(_ items: [Track], preserveOrder: Bool = false) {
        self.rebuildAllRows(from: items)
        if preserveOrder {
            if self.filterText.isEmpty {
                self.rows = self.allRows
            } else {
                let lowered = self.filterText.lowercased()
                self.rows = self.allRows.filter { $0.title.lowercased().contains(lowered) }
            }
        } else {
            self.applyFilter()
        }
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

    /// Maps a `(column, ascending)` pair onto `sortOrder`, so persisted
    /// `UIStateV1` values restore cleanly and existing tests stay green.
    public func setSort(column: TrackSortColumn, ascending: Bool) {
        let order: SortOrder = ascending ? .forward : .reverse
        self.applySort([Self.comparator(for: column, order: order)])
    }

    /// Seeds a multi-column sort from an ordered `(column, ascending)` list so
    /// the header arrows reflect the caller's ordering (e.g. a smart playlist's
    /// sort descriptors). No-op when empty, so callers can pass only mappable columns.
    public func setSort(columns: [(column: TrackSortColumn, ascending: Bool)]) {
        guard !columns.isEmpty else { return }
        let order = columns.map { pair in
            Self.comparator(for: pair.column, order: pair.ascending ? .forward : .reverse)
        }
        self.applySort(order)
    }

    /// Reverts to the default (Date Added, descending) sort order.
    public func resetSort() {
        self.applySort(Self.defaultSortOrder)
    }

    /// Clears any active column sort and restores the caller-provided baseline
    /// (a manual playlist's saved order): rows revert to `allRows` with the text
    /// filter still applied, and empty `sortOrder` clears the header arrow.
    public func restoreManualOrder() {
        self.sortOrder = []
        if self.filterText.isEmpty {
            self.rows = self.allRows
        } else {
            let lowered = self.filterText.lowercased()
            self.rows = self.allRows.filter { $0.title.lowercased().contains(lowered) }
        }
    }

    /// Called by `TracksView` whenever the Table's `@State sortOrder` changes.
    /// Deduplicates identical writes and resorts `rows` in place. Observation
    /// fires only for the `rows` reassignment, never for `sortOrder`, so the
    /// Table's per-frame binding writes cannot trigger a SwiftUI update cycle.
    public func applySort(_ order: [KeyPathComparator<TrackRow>]) {
        guard order != self.sortOrder else { return }
        self.sortOrder = order
        self.rows.sort(using: order)
    }

    // MARK: - Private

    /// Every artist, recovered to an empty list on a read failure. That blanks
    /// the table's artist column rather than the table itself, which is the
    /// right recovery, but a library that reads as having no artists at all
    /// must not look like an empty one (#491).
    private func allArtists() async -> [Artist] {
        do {
            return try await self.artistRepository.fetchAll()
        } catch {
            self.log.warning("tracks.artistNames.failed", ["error": String(reflecting: error)])
            return []
        }
    }

    /// Every album, recovered the same way as ``allArtists()`` and for the same
    /// reason, against the table's album column.
    private func allAlbums() async -> [Album] {
        do {
            return try await self.albumRepository.fetchAll()
        } catch {
            self.log.warning("tracks.albumNames.failed", ["error": String(reflecting: error)])
            return []
        }
    }

    private func refreshNameLookups() async {
        let artists = await self.allArtists()
        let albums = await self.allAlbums()
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
        self.albumArtPaths = Dictionary(
            uniqueKeysWithValues: albums.compactMap { album -> (Int64, String)? in
                guard let id = album.id, let path = album.coverArtPath else { return nil }
                return (id, path)
            }
        )
    }

    /// Rebuilds the unfiltered `allRows` backing array from `source`
    /// using the current artist/album name lookups.
    private func rebuildAllRows(from source: [Track]) {
        let artists = self.artistNames
        let albums = self.albumNames
        let artPaths = self.albumArtPaths
        self.allRows = source.map { track in
            TrackRow(
                track: track,
                artistName: track.artistID.flatMap { artists[$0] },
                albumName: track.albumID.flatMap { albums[$0] },
                albumCoverArtPath: track.albumID.flatMap { artPaths[$0] }
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

        case .trackTotal:
            KeyPathComparator(\TrackRow.trackTotal, order: order)

        case .databaseID:
            KeyPathComparator(\TrackRow.databaseID, order: order)
        }
    }

    private static let keyPathToColumn: [AnyKeyPath: TrackSortColumn] = [
        \TrackRow.title: .title,
        \TrackRow.artistName: .artist,
        \TrackRow.albumName: .album,
        \TrackRow.genre: .genre,
        \TrackRow.year: .year,
        \TrackRow.duration: .duration,
        \TrackRow.playCount: .playCount,
        \TrackRow.rating: .rating,
        \TrackRow.addedAt: .addedAt,
        \TrackRow.trackNumber: .trackNumber,
        \TrackRow.trackTotal: .trackTotal,
        \TrackRow.databaseID: .databaseID,
    ]

    /// Reverse of `comparator(for:order:)` — recovers the persisted
    /// column identifier from a live comparator so `LibraryViewModel`
    /// can serialise `UIStateV1` without a parallel source of truth.
    private static func column(for comparator: KeyPathComparator<TrackRow>) -> TrackSortColumn? {
        self.keyPathToColumn[comparator.keyPath]
    }
}
