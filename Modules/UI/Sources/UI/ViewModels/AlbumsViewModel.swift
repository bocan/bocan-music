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

    /// Maps artist ID → artist name, loaded alongside albums.
    @Published public private(set) var artistNames: [Int64: String] = [:]

    /// Maps album ID → non-disabled track count, loaded alongside albums.
    @Published public private(set) var trackCounts: [Int64: Int] = [:]

    // MARK: - Internal

    private let repository: AlbumRepository
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(repository: AlbumRepository) {
        self.repository = repository
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
            self.albums = albums
            self.artistNames = artistNames
            self.trackCounts = trackCounts
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

    /// Replaces the album list with a pre-fetched result (search results).
    public func setAlbums(_ items: [Album]) {
        self.albums = items
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
            self.albums = try await self.repository.search(query: query)
        } catch {
            self.log.error("albums.search.failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
    }
}
