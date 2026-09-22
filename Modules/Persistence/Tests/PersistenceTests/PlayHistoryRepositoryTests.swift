import Foundation
import Testing
@testable import Persistence

// MARK: - PlayHistoryRepositoryTests

/// The History page's read (ADR-094): one row per listen, newest first,
/// joined to the song's text, from Bòcan's own plays and the Last.fm
/// listens matched to a library song (slice 3, option C), filtered through
/// the same FTS5 index as the library search. Also pins the schema facts the
/// page makes visible: local plays cascade away with the song; imported
/// listens only unlink.
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
        let fileURL: String
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
        return Song(trackID: trackID, artistID: artistID, albumID: albumID, fileURL: track.fileURL)
    }

    /// Writes a local play the way `PlayHistoryRecorder` does.
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

    /// Writes an imported listen, linked to `trackID` when given, the way an
    /// import plus a re-match leaves it.
    @discardableResult
    private func insertImported(
        into db: Database,
        trackID: Int64?,
        playedAt: Int64,
        artist: String = "Wade Bowen",
        title: String = "Say Anything"
    ) async throws -> Int64 {
        try await db.write { db in
            try db.execute(
                sql: """
                INSERT INTO imported_listens (source, played_at, artist, title, track_id)
                VALUES ('lastfm', ?, ?, ?, ?)
                """,
                arguments: [playedAt, artist, title, trackID]
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
        #expect(Set(rows.map(\.id)).count == 3, "each listen carries its own key")
        #expect(rows.allSatisfy { $0.trackID == song.trackID && $0.source == .local })
    }

    @Test("Two plays in the same second break the tie on the row id, descending")
    func sameSecondTieBreaksOnID() async throws {
        let db = try await self.makeDatabase()
        let song = try await self.insertSong(into: db, title: "Say Anything")
        let first = try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now)
        let second = try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now)

        let rows = try await PlayHistoryRepository(database: db).recent()

        #expect(rows.map(\.rowID) == [second, first])
    }

    @Test("A row carries the song's title, artist, album, ids and file URL")
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
        #expect(row.fileURL == song.fileURL, "Show in Finder reveals from the row, with no second read")
    }

    // MARK: - Two sources (slice 3)

    @Test("Local plays and matched imported listens interleave by time, each with its source")
    func sourcesInterleaveByTime() async throws {
        let db = try await self.makeDatabase()
        let song = try await self.insertSong(into: db, title: "Say Anything")
        try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now + 100)
        try await self.insertImported(into: db, trackID: song.trackID, playedAt: self.now + 200)
        try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now + 300)

        let rows = try await PlayHistoryRepository(database: db).recent()

        #expect(rows.map(\.source) == [.local, .imported, .local])
        #expect(rows.map(\.playedAt) == [self.now + 300, self.now + 200, self.now + 100])
        #expect(rows[1].title == "Say Anything", "an imported listen carries the matched song's text")
        #expect(rows[1].fileURL == song.fileURL)
    }

    @Test("The same row id in both tables is two different keys")
    func keysAreDistinctAcrossSources() async throws {
        let db = try await self.makeDatabase()
        let song = try await self.insertSong(into: db, title: "Say Anything")
        let local = try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now)
        let imported = try await self.insertImported(into: db, trackID: song.trackID, playedAt: self.now + 1)
        #expect(local == imported, "the fixture needs colliding row ids to prove anything")

        let rows = try await PlayHistoryRepository(database: db).recent()

        #expect(Set(rows.map(\.id)).count == 2)
    }

    @Test("An imported listen with no matched song is not listed")
    func unmatchedImportedIsNotListed() async throws {
        let db = try await self.makeDatabase()
        let song = try await self.insertSong(into: db, title: "Say Anything")
        try await self.insertImported(into: db, trackID: song.trackID, playedAt: self.now)
        try await self.insertImported(into: db, trackID: nil, playedAt: self.now + 1, title: "Not Owned")

        let rows = try await PlayHistoryRepository(database: db).recent()

        #expect(rows.count == 1)
        #expect(rows.first?.title == "Say Anything")
    }

    @Test("The source filter lists one table or both")
    func sourceFilter() async throws {
        let db = try await self.makeDatabase()
        let song = try await self.insertSong(into: db, title: "Say Anything")
        try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now)
        try await self.insertImported(into: db, trackID: song.trackID, playedAt: self.now + 1)
        let repo = PlayHistoryRepository(database: db)

        #expect(try await repo.recent(source: .all).map(\.source) == [.imported, .local])
        #expect(try await repo.recent(source: .local).map(\.source) == [.local])
        #expect(try await repo.recent(source: .imported).map(\.source) == [.imported])
    }

    @Test("Removing a song unlinks its imported listens instead of deleting them")
    func removingTheSongUnlinksImported() async throws {
        let db = try await self.makeDatabase()
        let song = try await self.insertSong(into: db, title: "Say Anything")
        try await self.insertImported(into: db, trackID: song.trackID, playedAt: self.now)

        try await db.write { db in
            try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [song.trackID])
        }
        let listed = try await PlayHistoryRepository(database: db).recent()
        let kept: Int = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM imported_listens WHERE track_id IS NULL") ?? 0
        }

        #expect(listed.isEmpty, "it drops out of History, having no song")
        #expect(kept == 1, "but the listen itself survives, unlinked (ON DELETE SET NULL)")
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

    @Test("A listen of a song whose file has gone lists as missing, from either source")
    func missingFileIsFlagged() async throws {
        let db = try await self.makeDatabase()
        let present = try await self.insertSong(into: db, title: "Present")
        let gone = try await self.insertSong(
            into: db, title: "Gone", artist: "Tyler Childers", album: "Purgatory"
        )
        try await self.insertPlay(into: db, trackID: present.trackID, playedAt: self.now)
        try await self.insertPlay(into: db, trackID: gone.trackID, playedAt: self.now + 1)
        try await self.insertImported(into: db, trackID: gone.trackID, playedAt: self.now + 2)
        try await db.write { db in
            try db.execute(sql: "UPDATE tracks SET disabled = 1 WHERE id = ?", arguments: [gone.trackID])
        }

        let rows = try await PlayHistoryRepository(database: db).recent()

        #expect(rows.map(\.isMissing) == [true, true, false])
        #expect(rows.map(\.source) == [.imported, .local, .local])
        #expect(rows.first?.title == "Gone", "the listen still lists, with its song's text")
    }

    @Test("Deleting a song deletes its local plays: play_history.track_id cascades (M001)")
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

    @Test("matching finds listens of a song by title, artist and album, from both sources")
    func matchingFindsByTitleArtistAndAlbum() async throws {
        let db = try await self.makeDatabase()
        let bowen = try await self.insertSong(into: db, title: "Say Anything")
        let other = try await self.insertSong(
            into: db, title: "Blue Ridge", artist: "Tyler Childers", album: "Purgatory"
        )
        try await self.insertPlay(into: db, trackID: bowen.trackID, playedAt: self.now)
        try await self.insertImported(into: db, trackID: other.trackID, playedAt: self.now + 1)
        let repo = PlayHistoryRepository(database: db)

        let byTitle = try await repo.recent(matching: "Anything")
        let byArtist = try await repo.recent(matching: "childers")
        let byAlbum = try await repo.recent(matching: "Purgatory")
        let none = try await repo.recent(matching: "zzzz")

        #expect(byTitle.map(\.trackID) == [bowen.trackID])
        #expect(byArtist.map(\.trackID) == [other.trackID], "an imported listen matches through its song")
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

    @Test("limit caps the result at the newest rows across both sources")
    func limitCapsTheNewest() async throws {
        let db = try await self.makeDatabase()
        let song = try await self.insertSong(into: db, title: "Say Anything")
        for offset in 0 ..< 3 {
            try await self.insertPlay(into: db, trackID: song.trackID, playedAt: self.now + Int64(offset) * 2)
        }
        for offset in 0 ..< 3 {
            try await self.insertImported(into: db, trackID: song.trackID, playedAt: self.now + Int64(offset) * 2 + 1)
        }

        let rows = try await PlayHistoryRepository(database: db).recent(limit: 3)

        #expect(rows.map(\.playedAt) == [self.now + 5, self.now + 4, self.now + 3])
        #expect(rows.map(\.source) == [.imported, .local, .imported])
    }
}
