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
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .year: "Year"
        case .genre: "Genre"
        case .duration: "Time"
        case .playCount: "Plays"
        case .rating: "Rating"
        case .addedAt: "Date Added"
        case .trackNumber: "#"
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

    // MARK: - Internal

    private let repository: TrackRepository
    private var allTracks: [Track] = []
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(repository: TrackRepository) {
        self.repository = repository
    }

    // MARK: - Public API

    /// (Re)loads all tracks from the database and applies current sort/filter.
    public func load() async {
        self.isLoading = true
        self.log.debug("tracks.load.start", [:])
        do {
            self.allTracks = try await self.repository.fetchAll()
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

    /// Updates the sort and re-sorts the visible array.
    public func setSort(column: TrackSortColumn, ascending: Bool) {
        self.sortColumn = column
        self.sortAscending = ascending
        self.applyFilter()
    }

    // MARK: - Private

    private func applyFilter() {
        var result = self.allTracks

        // Client-side text filter for local display
        if !self.filterText.isEmpty {
            let q = self.filterText.lowercased()
            result = result.filter {
                ($0.title ?? "").lowercased().contains(q)
            }
        }

        result.sort { a, b in
            let asc = self.sortAscending
            switch self.sortColumn {
            case .title: return self.compare(a.title, b.title, ascending: asc)
            case .album: return self.compare(a.albumID, b.albumID, ascending: asc)
            case .artist: return self.compare(a.artistID, b.artistID, ascending: asc)
            case .year: return self.compare(a.year, b.year, ascending: asc)
            case .genre: return self.compare(a.genre, b.genre, ascending: asc)
            case .duration: return asc ? a.duration < b.duration : a.duration > b.duration
            case .playCount: return asc ? a.playCount < b.playCount : a.playCount > b.playCount
            case .rating: return asc ? a.rating < b.rating : a.rating > b.rating
            case .addedAt: return asc ? a.addedAt < b.addedAt : a.addedAt > b.addedAt
            case .trackNumber: return self.compare(a.trackNumber, b.trackNumber, ascending: asc)
            }
        }

        self.tracks = result
    }

    // MARK: - Sort helpers

    private func compare<T: Comparable>(_ a: T?, _ b: T?, ascending: Bool) -> Bool {
        switch (a, b) {
        case let (a?, b?): ascending ? a < b : a > b
        case (.some, .none): ascending
        case (.none, .some): !ascending
        case (.none, .none): false
        }
    }

    private func compare(_ a: String?, _ b: String?, ascending: Bool) -> Bool {
        let la = (a ?? "").localizedCaseInsensitiveCompare(b ?? "")
        if ascending { return la == .orderedAscending }
        return la == .orderedDescending
    }
}
