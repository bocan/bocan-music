import Foundation
import GRDB
import Observability

// MARK: - LibrarySummaryStats

/// Whole-library aggregate counts for the Library Summary window (#373).
/// Every figure counts enabled tracks only, matching what the browse views
/// show; disabled rows are invisible in the UI so they don't count here.
public struct LibrarySummaryStats: Equatable, Sendable {
    /// Enabled tracks.
    public let songCount: Int
    /// Albums with at least one enabled track.
    public let albumCount: Int
    /// Distinct track-level artists with at least one enabled track.
    public let artistCount: Int
    /// Distinct artists credited as the album artist of at least one album
    /// with an enabled track (the Artists view's "Album Artists" scope).
    public let albumArtistCount: Int
    /// Sum of enabled tracks' durations, in seconds.
    public let totalDuration: TimeInterval

    public init(
        songCount: Int,
        albumCount: Int,
        artistCount: Int,
        albumArtistCount: Int,
        totalDuration: TimeInterval
    ) {
        self.songCount = songCount
        self.albumCount = albumCount
        self.artistCount = artistCount
        self.albumArtistCount = albumArtistCount
        self.totalDuration = totalDuration
    }
}

// MARK: - LibraryStatsRepository

/// Read-only aggregate queries over the whole library.
public struct LibraryStatsRepository: Sendable {
    private let database: Database

    /// Creates a repository backed by `database`.
    public init(database: Database) {
        self.database = database
    }

    /// Fetches all summary figures in a single read transaction so the counts
    /// are mutually consistent even while a scan is writing.
    public func fetchSummary() async throws -> LibrarySummaryStats {
        try await self.database.read { db in
            let songs = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tracks WHERE disabled = 0
            """) ?? 0
            let albums = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT album_id) FROM tracks
                WHERE disabled = 0 AND album_id IS NOT NULL
            """) ?? 0
            let artists = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT artist_id) FROM tracks
                WHERE disabled = 0 AND artist_id IS NOT NULL
            """) ?? 0
            let albumArtists = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT albums.album_artist_id)
                FROM albums
                JOIN tracks ON tracks.album_id = albums.id AND tracks.disabled = 0
                WHERE albums.album_artist_id IS NOT NULL
            """) ?? 0
            let duration = try Double.fetchOne(db, sql: """
                SELECT COALESCE(SUM(duration), 0) FROM tracks WHERE disabled = 0
            """) ?? 0
            return LibrarySummaryStats(
                songCount: songs,
                albumCount: albums,
                artistCount: artists,
                albumArtistCount: albumArtists,
                totalDuration: duration
            )
        }
    }
}
