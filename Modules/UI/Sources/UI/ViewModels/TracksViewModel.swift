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
@MainActor
public final class TracksViewModel: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var isLoading = false
    @Published public var selection: Set<Track.ID> = []

    /// Active sort: column + ascending flag.
    @Published public var sortColumn: TrackSortColumn = .addedAt
    @Published public var sortAscending = false

    /// Free-text filter (operates client-side for in-memory arrays).
    @Published public var filterText = ""

    /// Maps `artistID → artist name` for column display.  Refreshed on every load.
    @Published public private(set) var artistNames: [Int64: String] = [:]

    /// Maps `albumID → album title` for column display.  Refreshed on every load.
    @Published public private(set) var albumNames: [Int64: String] = [:]

    // MARK: - Internal

    private let repository: TrackRepository
    private let artistRepository: ArtistRepository
    private let albumRepository: AlbumRepository
    private var allTracks: [Track] = []
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
            self.allTracks = try await self.repository.fetchAll()
            await self.refreshNameLookups()
            self.applyFilter()
            self.log.debug("tracks.load.end", ["count": self.allTracks.count])
        } catch {
            self.log.error("tracks.load.failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }

    /// Loads tracks for a specific album.
    public func load(albumID: Int64) async {
        self.isLoading = true
        do {
            self.allTracks = try await self.repository.fetchAll(albumID: albumID)
            await self.refreshNameLookups()
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
            self.allTracks = try await self.repository.fetchAll(artistID: artistID)
            await self.refreshNameLookups()
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
            self.allTracks = try await self.repository.fetchAll(genre: genre)
            await self.refreshNameLookups()
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
            self.allTracks = try await self.repository.fetchAll(composer: composer)
            await self.refreshNameLookups()
            self.applyFilter()
        } catch {
            self.log.error("tracks.load(composer).failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }

    /// Sets a pre-fetched track list directly (used by smart folders / search results).
    public func setTracks(_ items: [Track]) {
        self.allTracks = items
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

    /// Updates the sort and re-sorts the visible array.
    public func setSort(column: TrackSortColumn, ascending: Bool) {
        // Skip redundant work to avoid thrashing @Published subscribers
        // when callers re-apply the existing sort state.
        guard column != self.sortColumn || ascending != self.sortAscending else { return }
        self.sortColumn = column
        self.sortAscending = ascending
        self.applyFilter()
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

    private func applyFilter() {
        self.tracks = Self.sortedAndFiltered(
            self.allTracks,
            filter: self.filterText,
            column: self.sortColumn,
            ascending: self.sortAscending,
            artistNames: self.artistNames,
            albumNames: self.albumNames
        )
    }

    /// Pure, Sendable sort-and-filter.  Safe to call from a detached task.
    nonisolated static func sortedAndFiltered(
        _ source: [Track],
        filter: String,
        column: TrackSortColumn,
        ascending: Bool,
        artistNames: [Int64: String],
        albumNames: [Int64: String]
    ) -> [Track] {
        var result = source
        if !filter.isEmpty {
            let lowered = filter.lowercased()
            result = result.filter { ($0.title ?? "").lowercased().contains(lowered) }
        }

        result.sort { lhs, rhs in
            switch column {
            case .title:
                Self.compare(lhs.title, rhs.title, ascending: ascending)

            case .album:
                Self.compare(
                    lhs.albumID.flatMap { albumNames[$0] },
                    rhs.albumID.flatMap { albumNames[$0] },
                    ascending: ascending
                )

            case .artist:
                Self.compare(
                    lhs.artistID.flatMap { artistNames[$0] },
                    rhs.artistID.flatMap { artistNames[$0] },
                    ascending: ascending
                )

            case .year:
                Self.compare(lhs.year, rhs.year, ascending: ascending)

            case .genre:
                Self.compare(lhs.genre, rhs.genre, ascending: ascending)

            case .duration:
                ascending ? lhs.duration < rhs.duration : lhs.duration > rhs.duration

            case .playCount:
                ascending ? lhs.playCount < rhs.playCount : lhs.playCount > rhs.playCount

            case .rating:
                ascending ? lhs.rating < rhs.rating : lhs.rating > rhs.rating

            case .addedAt:
                ascending ? lhs.addedAt < rhs.addedAt : lhs.addedAt > rhs.addedAt

            case .trackNumber:
                Self.compare(lhs.trackNumber, rhs.trackNumber, ascending: ascending)
            }
        }

        return result
    }

    // MARK: - Sort helpers

    private nonisolated static func compare<T: Comparable>(_ lhs: T?, _ rhs: T?, ascending: Bool) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            ascending ? lhs < rhs : lhs > rhs

        case (.some, .none):
            ascending

        case (.none, .some):
            !ascending

        case (.none, .none):
            false
        }
    }

    private nonisolated static func compare(_ lhs: String?, _ rhs: String?, ascending: Bool) -> Bool {
        // Use default String `<` (not localized).  This is ~10x faster than
        // localizedCaseInsensitiveCompare, matches the comparator SwiftUI's
        // KeyPathComparator uses on String keypaths, and keeps the sort
        // strictly on the main thread without race-prone async indirection.
        let lhs = lhs ?? ""
        let rhs = rhs ?? ""
        return ascending ? lhs < rhs : lhs > rhs
    }
}
