import Foundation
import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicGenresViewModel

/// Drives the per-server Genres destination (Phase 19 step 10).
///
/// The top of the view shows the flat list of genres with song counts.
/// Selecting a genre lazy-loads its songs via `getSongsByGenre` with
/// `count`/`offset` paging at `pageSize`.
@MainActor
public final class SubsonicGenresViewModel: ObservableObject {
    public static let pageSize = 100

    public let serverID: UUID

    @Published public private(set) var genres: [Genre] = []
    @Published public private(set) var isLoadingGenres = false
    @Published public var errorMessage: String?

    @Published public var selectedGenre: String?
    @Published public private(set) var genreSongs: [Song] = []
    @Published public private(set) var isLoadingGenreSongs = false
    @Published public private(set) var hasMoreGenreSongs = true

    private let dataSource: any SubsonicBrowseDataSource
    private let log = AppLogger.make(.ui)

    public init(serverID: UUID, dataSource: any SubsonicBrowseDataSource) {
        self.serverID = serverID
        self.dataSource = dataSource
    }

    public func load() async {
        guard !self.isLoadingGenres else { return }
        self.isLoadingGenres = true
        defer { self.isLoadingGenres = false }

        do {
            self.genres = try await self.dataSource.getGenres(serverID: self.serverID)
            self.errorMessage = nil
        } catch {
            self.log.error("subsonic.genres.load.failed", ["error": String(reflecting: error)])
            self.genres = []
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Could not load genres from this server."
        }
    }

    /// Selects a genre and loads its first page of songs. Pass `nil` to clear.
    public func selectGenre(_ genre: String?) async {
        self.selectedGenre = genre
        self.genreSongs = []
        self.hasMoreGenreSongs = (genre != nil)
        if genre != nil {
            await self.loadMoreGenreSongs()
        }
    }

    public func loadMoreGenreSongs() async {
        guard let genre = self.selectedGenre,
              !self.isLoadingGenreSongs,
              self.hasMoreGenreSongs else { return }
        self.isLoadingGenreSongs = true
        defer { self.isLoadingGenreSongs = false }

        do {
            let batch = try await self.dataSource.getSongsByGenre(
                serverID: self.serverID,
                genre: genre,
                count: Self.pageSize,
                offset: self.genreSongs.count
            )
            self.genreSongs.append(contentsOf: batch)
            if batch.count < Self.pageSize {
                self.hasMoreGenreSongs = false
            }
            self.errorMessage = nil
        } catch {
            self.log.error("subsonic.genreSongs.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Could not load songs for this genre."
        }
    }
}
