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
        var result = self.allTracks

        // Client-side text filter for local display
        if !self.filterText.isEmpty {
            let lowercasedFilter = self.filterText.lowercased()
            result = result.filter {
                ($0.title ?? "").lowercased().contains(lowercasedFilter)
            }
        }

        result.sort { lhs, rhs in
            let asc = self.sortAscending
            switch self.sortColumn {
            case .title:
                return self.compare(lhs.title, rhs.title, ascending: asc)

            case .album:
                let lName = lhs.albumID.flatMap { self.albumNames[$0] }
                let rName = rhs.albumID.flatMap { self.albumNames[$0] }
                return self.compare(lName, rName, ascending: asc)

            case .artist:
                let lName = lhs.artistID.flatMap { self.artistNames[$0] }
                let rName = rhs.artistID.flatMap { self.artistNames[$0] }
                return self.compare(lName, rName, ascending: asc)

            case .year:
                return self.compare(lhs.year, rhs.year, ascending: asc)

            case .genre:
                return self.compare(lhs.genre, rhs.genre, ascending: asc)

            case .duration:
                return asc ? lhs.duration < rhs.duration : lhs.duration > rhs.duration

            case .playCount:
                return asc ? lhs.playCount < rhs.playCount : lhs.playCount > rhs.playCount

            case .rating:
                return asc ? lhs.rating < rhs.rating : lhs.rating > rhs.rating

            case .addedAt:
                return asc ? lhs.addedAt < rhs.addedAt : lhs.addedAt > rhs.addedAt

            case .trackNumber:
                return self.compare(lhs.trackNumber, rhs.trackNumber, ascending: asc)
            }
        }

        self.tracks = result
    }

    // MARK: - Sort helpers

    private func compare<T: Comparable>(_ lhs: T?, _ rhs: T?, ascending: Bool) -> Bool {
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

    private func compare(_ lhs: String?, _ rhs: String?, ascending: Bool) -> Bool {
        let result = (lhs ?? "").localizedCaseInsensitiveCompare(rhs ?? "")
        if ascending { return result == .orderedAscending }
        return result == .orderedDescending
    }
}
