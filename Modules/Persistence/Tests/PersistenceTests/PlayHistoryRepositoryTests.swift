import Foundation
import Testing
@testable import Persistence

// MARK: - PlayHistoryRepositoryTests

/// The History page's read (ADR-094): one row per play, newest first, joined
/// to the song's text, filtered through the same FTS5 index as the library
/// search. Also pins the schema fact the page makes visible: a song's plays
/// cascade away with the song.
@Suite("PlayHistoryRepository")
struct PlayHistoryRepositoryTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private var now: Int64 {
        1_700_000_000
    }

    private struct Song {
        let trackID: Int64
        let artistID: Int64?
        let albumID: Int64?
    }

    /// Inserts an artist, an album and a song on both, and returns the ids.
    private func insertSong(
        into db: Database,
        title: String,
        artist: String? = "Wade Bowen",
        album: String? = "Somewhere Between the Secret and the Truth",
        duration: Double = 245
    ) async throws -> Song {
        let artistID: Int64? = if let artist {
            try await ArtistRepository(database: db).insert(Artist(name: artist))
        } else {
            nil
        }
        let albumID: Int64? = if let album {
            try await AlbumRepository(database: db).insert(
                Album(title: album, albumArtistID: artistID, year: 2022, coverArtPath: nil)
            )
        } else {
            nil
        }
        let track = Track(
            fileURL: "file:///tmp/\(UUID().uuidString).flac",
            fileSize: 1024,
            fileMtime: self.now,
            fileFormat: "flac",
            duration: duration,
            title: title,
            artistID: artistID,
            albumID: albumID,
            addedAt: self.now,
            updatedAt: self.now
        )
        let trackID = try await TrackRepository(database: db).insert(track)
        return Song(trackID: trackID, artistID: artistID, albumID: albumID)
    }

    /// Writes a play the way `PlayHistoryRecorder` does.
    @discardableResult
    private func insertPlay(
        into db: Database,
        trackID: Int64,
        playedAt: Int64,
        durationPlayed: Double = 130
    ) async throws -> Int64 {
        try await db.write { db in
            try db.execute(
                sql: """
                INSERT INTO play_history (track_id, played_at, duration_played, source)
                VALUES (?, ?, ?, 'queue')
                """,
                arguments: [trackID, playedAt, durationPlayed]
            )
            return db.lastInsertedRowID
        }
    }

    // MARK: - Order and identity

    @Test("One song played three times is three rows, newest first")
    func onePlayPerRowNewestFirst() async throws {
        let db = try await self.makeDatabase()
        let song = try await self.insertSong(into: db, title: "Say Anything")
        try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now)
        try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now + 600)
        try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now + 300)

        let rows = try await PlayHistoryRepository(database: db).recent()

        #expect(rows.count == 3)
        #expect(rows.map(\.playedAt) == [self.now + 600, self.now + 300, self.now])
        #expect(Set(rows.map(\.playID)).count == 3, "each play carries its own id")
        #expect(rows.allSatisfy { $0.trackID == song.trackID })
    }

    @Test("Two plays in the same second break the tie on the play id, descending")
    func sameSecondTieBreaksOnID() async throws {
        let db = try await self.makeDatabase()
        let song = try await self.insertSong(into: db, title: "Say Anything")
        let first = try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now)
        let second = try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now)

        let rows = try await PlayHistoryRepository(database: db).recent()

        #expect(rows.map(\.playID) == [second, first])
    }

    @Test("A row carries the song's title, artist, album, ids and length")
    func rowCarriesTheSongsText() async throws {
        let db = try await self.makeDatabase()
        let song = try await self.insertSong(into: db, title: "Say Anything", duration: 245)
        try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now, durationPlayed: 130)

        let row = try #require(try await PlayHistoryRepository(database: db).recent().first)

        #expect(row.title == "Say Anything")
        #expect(row.artistName == "Wade Bowen")
        #expect(row.albumName == "Somewhere Between the Secret and the Truth")
        #expect(row.artistID == song.artistID)
        #expect(row.albumID == song.albumID)
        #expect(row.trackDuration == 245)
        #expect(row.durationPlayed == 130)
    }

    // MARK: - Missing joins

    @Test("A song with no artist and no album still lists, with those columns empty")
    func songWithoutArtistOrAlbumStillLists() async throws {
        let db = try await self.makeDatabase()
        let song = try await self.insertSong(into: db, title: "Untagged", artist: nil, album: nil)
        try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now)

        let row = try #require(try await PlayHistoryRepository(database: db).recent().first)

        #expect(row.title == "Untagged")
        #expect(row.artistName == nil)
        #expect(row.albumName == nil)
        #expect(row.artistID == nil)
        #expect(row.albumID == nil)
    }

    @Test("Deleting a song deletes its plays: play_history.track_id cascades (M001)")
    func removingTheSongRemovesItsPlays() async throws {
        let db = try await self.makeDatabase()
        let kept = try await self.insertSong(into: db, title: "Kept")
        let removed = try await self.insertSong(
            into: db, title: "Removed", artist: "Tyler Childers", album: "Purgatory"
        )
        try await self.insertPlay(into: db, trackID: kept.trackID, playedAt: self.now)
        try await self.insertPlay(into: db, trackID: removed.trackID, playedAt: self.now + 1)

        try await db.write { db in
            try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [removed.trackID])
        }
        let rows = try await PlayHistoryRepository(database: db).recent()

        #expect(rows.map(\.trackID) == [kept.trackID], "the removed song's play went with it")
    }

    // MARK: - Matching

    @Test("matching finds plays by the song's title, artist and album")
    func matchingFindsByTitleArtistAndAlbum() async throws {
        let db = try await self.makeDatabase()
        let bowen = try await self.insertSong(into: db, title: "Say Anything")
        let other = try await self.insertSong(
            into: db, title: "Blue Ridge", artist: "Tyler Childers", album: "Purgatory"
        )
        try await self.insertPlay(into: db, trackID: bowen.trackID, playedAt: self.now)
        try await self.insertPlay(into: db, trackID: other.trackID, playedAt: self.now + 1)
        let repo = PlayHistoryRepository(database: db)

        let byTitle = try await repo.recent(matching: "Anything")
        let byArtist = try await repo.recent(matching: "childers")
        let byAlbum = try await repo.recent(matching: "Purgatory")
        let none = try await repo.recent(matching: "zzzz")

        #expect(byTitle.map(\.trackID) == [bowen.trackID])
        #expect(byArtist.map(\.trackID) == [other.trackID])
        #expect(byAlbum.map(\.trackID) == [other.trackID])
        #expect(none.isEmpty)
    }

    @Test("A blank term is no filter, and FTS syntax in the term is escaped rather than parsed")
    func blankAndHostileTerms() async throws {
        let db = try await self.makeDatabase()
        let song = try await self.insertSong(into: db, title: "Say Anything")
        try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now)
        let repo = PlayHistoryRepository(database: db)

        #expect(try await repo.recent(matching: "   ").count == 1)
        // Unbalanced quotes and operators are a syntax error unescaped; escaped,
        // they are ordinary tokens, and the read must not throw.
        await #expect(throws: Never.self) { try await repo.recent(matching: "\"say OR (") }
        await #expect(throws: Never.self) { try await repo.recent(matching: "NOT * \"") }
    }

    // MARK: - Limit

    @Test("limit caps the result at the newest rows")
    func limitCapsTheNewest() async throws {
        let db = try await self.makeDatabase()
        let song = try await self.insertSong(into: db, title: "Say Anything")
        for offset in 0 ..< 5 {
            try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now + Int64(offset))
        }

        let rows = try await PlayHistoryRepository(database: db).recent(limit: 2)

        #expect(rows.map(\.playedAt) == [self.now + 4, self.now + 3])
    }
}
