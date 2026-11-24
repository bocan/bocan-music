import Foundation
import Testing
@testable import Persistence

// MARK: - AlbumRepositoryRecentlyAddedTests

/// The albums behind Recently Added's Albums mode and the "Date Added" album
/// sort (#700).
@Suite("Album Repository Recently Added")
struct AlbumRepositoryRecentlyAddedTests {
    private static let day: Int64 = 86400
    /// The reference "now" every test measures its window from.
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let nowSeconds = Int64(1_700_000_000)

    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func insertAlbum(_ repo: AlbumRepository, _ title: String, year: Int? = nil) async throws -> Int64 {
        try await repo.insert(Album(title: title, year: year))
    }

    /// Inserts a track on `albumID` added `daysAgo` days before `now`.
    private func insertTrack(
        _ repo: TrackRepository,
        albumID: Int64?,
        daysAgo: Int64,
        disabled: Bool = false
    ) async throws {
        let addedAt = Self.nowSeconds - daysAgo * Self.day
        var track = Track(
            fileURL: "file:///tmp/\(UUID().uuidString).flac",
            fileFormat: "flac",
            duration: 180,
            title: "Song",
            albumID: albumID,
            addedAt: addedAt,
            updatedAt: addedAt
        )
        track.disabled = disabled
        _ = try await repo.insert(track)
    }

    @Test("Lists albums with a song added inside the window, newest addition first")
    func newestFirst() async throws {
        let db = try await self.makeDatabase()
        let albums = AlbumRepository(database: db)
        let tracks = TrackRepository(database: db)
        // The release year must not matter: the old record was added last.
        let older = try await self.insertAlbum(albums, "Older Import", year: 2024)
        let newer = try await self.insertAlbum(albums, "Newer Import", year: 1969)
        try await self.insertTrack(tracks, albumID: older, daysAgo: 10)
        try await self.insertTrack(tracks, albumID: older, daysAgo: 9)
        try await self.insertTrack(tracks, albumID: newer, daysAgo: 2)

        let result = try await albums.fetchRecentlyAdded(days: 30, now: Self.now)
        #expect(result.map(\.title) == ["Newer Import", "Older Import"])
    }

    @Test("Lists each album once, however many of its songs were added")
    func distinctAlbums() async throws {
        let db = try await self.makeDatabase()
        let albums = AlbumRepository(database: db)
        let tracks = TrackRepository(database: db)
        let album = try await self.insertAlbum(albums, "Full Album")
        for _ in 0 ..< 12 {
            try await self.insertTrack(tracks, albumID: album, daysAgo: 1)
        }
        let result = try await albums.fetchRecentlyAdded(days: 30, now: Self.now)
        #expect(result.map(\.title) == ["Full Album"])
    }

    @Test("An album that gained a song inside the window sorts by that song")
    func latestAdditionCounts() async throws {
        let db = try await self.makeDatabase()
        let albums = AlbumRepository(database: db)
        let tracks = TrackRepository(database: db)
        let completed = try await self.insertAlbum(albums, "Completed")
        let recent = try await self.insertAlbum(albums, "Recent")
        try await self.insertTrack(tracks, albumID: completed, daysAgo: 400)
        try await self.insertTrack(tracks, albumID: completed, daysAgo: 1)
        try await self.insertTrack(tracks, albumID: recent, daysAgo: 5)

        let result = try await albums.fetchRecentlyAdded(days: 30, now: Self.now)
        #expect(result.map(\.title) == ["Completed", "Recent"])
    }

    @Test("Leaves out old albums, missing files and songs with no album")
    func exclusions() async throws {
        let db = try await self.makeDatabase()
        let albums = AlbumRepository(database: db)
        let tracks = TrackRepository(database: db)
        let old = try await self.insertAlbum(albums, "Old")
        let missing = try await self.insertAlbum(albums, "Missing File")
        let kept = try await self.insertAlbum(albums, "Kept")
        try await self.insertTrack(tracks, albumID: old, daysAgo: 31)
        try await self.insertTrack(tracks, albumID: missing, daysAgo: 1, disabled: true)
        try await self.insertTrack(tracks, albumID: nil, daysAgo: 1)
        try await self.insertTrack(tracks, albumID: kept, daysAgo: 30)

        let result = try await albums.fetchRecentlyAdded(days: 30, now: Self.now)
        #expect(result.map(\.title) == ["Kept"])
    }

    @Test("Albums added in the same second fall back to title order")
    func tiesByTitle() async throws {
        let db = try await self.makeDatabase()
        let albums = AlbumRepository(database: db)
        let tracks = TrackRepository(database: db)
        let zeta = try await self.insertAlbum(albums, "Zeta")
        let alpha = try await self.insertAlbum(albums, "Alpha")
        try await self.insertTrack(tracks, albumID: zeta, daysAgo: 3)
        try await self.insertTrack(tracks, albumID: alpha, daysAgo: 3)

        let result = try await albums.fetchRecentlyAdded(days: 30, now: Self.now)
        #expect(result.map(\.title) == ["Alpha", "Zeta"])
    }

    @Test("The latest-added map holds each album's newest enabled song")
    func latestAddedAtMap() async throws {
        let db = try await self.makeDatabase()
        let albums = AlbumRepository(database: db)
        let tracks = TrackRepository(database: db)
        let first = try await self.insertAlbum(albums, "First")
        let gone = try await self.insertAlbum(albums, "Gone")
        let empty = try await self.insertAlbum(albums, "Empty")
        try await self.insertTrack(tracks, albumID: first, daysAgo: 100)
        try await self.insertTrack(tracks, albumID: first, daysAgo: 7)
        // A disabled song must not move the album's date.
        try await self.insertTrack(tracks, albumID: first, daysAgo: 1, disabled: true)
        try await self.insertTrack(tracks, albumID: gone, daysAgo: 1, disabled: true)

        let map = try await albums.fetchLatestAddedAt()
        #expect(map[first] == Self.nowSeconds - 7 * Self.day)
        #expect(map[gone] == nil)
        #expect(map[empty] == nil)
    }
}
