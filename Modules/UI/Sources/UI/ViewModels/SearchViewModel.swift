import Combine
import Foundation
import Observability
import Persistence

// MARK: - Search result model

/// Grouped search results returned by `SearchViewModel`.
public struct SearchResults: Sendable {
    public var tracks: [TrackSearchHit]
    public var albums: [Album]
    public var artists: [Artist]

    public var isEmpty: Bool {
        self.tracks.isEmpty && self.albums.isEmpty && self.artists.isEmpty
    }

    public static let empty = Self(tracks: [], albums: [], artists: [])
}

// MARK: - SearchViewModel

/// Drives the global search field.
///
/// Debounces input by 250 ms, then runs FTS queries on all three entity
/// types in parallel.  In-flight requests are cancelled on new input.
@MainActor
public final class SearchViewModel: ObservableObject {
    // MARK: - Published state

    @Published public var query = ""
    @Published public private(set) var results = SearchResults.empty
    @Published public private(set) var isSearching = false

    // MARK: - Internal

    private let trackRepo: TrackRepository
    private let albumRepo: AlbumRepository
    private let artistRepo: ArtistRepository
    private var debounceTask: Task<Void, Never>?
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(
        trackRepo: TrackRepository,
        albumRepo: AlbumRepository,
        artistRepo: ArtistRepository
    ) {
        self.trackRepo = trackRepo
        self.albumRepo = albumRepo
        self.artistRepo = artistRepo
    }

    // MARK: - Public API

    /// Call whenever `query` changes to trigger a debounced search.
    public func queryChanged() {
        self.debounceTask?.cancel()
        let trimmed = self.query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            self.results = .empty
            self.isSearching = false
            return
        }
        self.isSearching = true
        self.debounceTask = Task {
            // 250ms debounce
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self.runSearch(query: trimmed)
        }
    }

    /// Clears the search results and query.
    public func clear() {
        self.debounceTask?.cancel()
        self.query = ""
        self.results = .empty
        self.isSearching = false
    }

    // MARK: - Private

    private func runSearch(query: String) async {
        self.log.debug("search.start", ["query": query])
        do {
            async let tracksFetch = self.trackRepo.searchRich(query: query)
            async let albumsFetch = self.albumRepo.search(query: query)
            async let artistsFetch = self.artistRepo.search(query: query)
            let (tracks, albums, artists) = try await (tracksFetch, albumsFetch, artistsFetch)
            guard !Task.isCancelled else { return }
            self.results = SearchResults(tracks: tracks, albums: albums, artists: artists)
            self.log.debug("search.end", [
                "tracks": tracks.count,
                "albums": albums.count,
                "artists": artists.count,
            ])
        } catch {
            self.log.error("search.failed", ["error": String(reflecting: error)])
        }
        self.isSearching = false
    }
}
