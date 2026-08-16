import Foundation
import Testing
@testable import Persistence

/// The backfilled listening-history store (ADR-076 slice 1): idempotent inserts,
/// the re-match pass, local-overlap dedupe, and the one-statement undo.
@Suite("ListenImportRepository")
struct ListenImportRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    /// Seeds one artist + track, returning the track id.
    private func seedTrack(
        _ db: Database,
        artistName: String,
        title: String,
        mbid: String? = nil
    ) async throws -> Int64 {
        try await db.write { db in
            var artist = Artist(name: artistName)
            try artist.insert(db)
            var track = Track(
                fileURL: "file:///tmp/\(artistName)-\(title).flac",
                fileFormat: "flac",
                duration: 200,
                title: title,
                addedAt: 0,
                updatedAt: 0
            )
            track.artistID = artist.id
            track.musicbrainzTrackID = mbid
            try track.insert(db)
            return try #require(track.id)
        }
    }

    private func listen(
        at playedAt: Int64,
        artist: String,
        title: String,
        mbid: String? = nil
    ) -> ImportedListen {
        ImportedListen(playedAt: playedAt, artist: artist, title: title, trackMbid: mbid)
    }

    @Test("Re-importing the same rows inserts nothing new")
    func insertIsIdempotent() async throws {
        let db = try await makeDB()
        let repo = ListenImportRepository(database: db)
        let rows = [
            self.listen(at: 1000, artist: "Wade Bowen", title: "Turpentine"),
            self.listen(at: 2000, artist: "Kaylee Rose", title: "Shovel"),
        ]
        #expect(try await repo.insert(rows) == 2)
        #expect(try await repo.insert(rows) == 0, "the identity index must swallow duplicates")
        let counts = try await repo.counts()
        #expect(counts.total == 2)
        #expect(counts.matched == 0)
        #expect(counts.unmatched == 2)
    }

    @Test("Rematch links by normalised artist and title, and by MusicBrainz id")
    func rematchLinksRows() async throws {
        let db = try await makeDB()
        let repo = ListenImportRepository(database: db)
        let byName = try await self.seedTrack(db, artistName: "Wade Bowen", title: "Turpentine")
        let byMbid = try await self.seedTrack(
            db,
            artistName: "Renamed Artist",
            title: "Retitled",
            mbid: "mbid-123"
        )

        _ = try await repo.insert([
            self.listen(at: 1000, artist: "wade BOWEN", title: "  turpentine "),
            self.listen(at: 2000, artist: "Old Name", title: "Old Title", mbid: "mbid-123"),
            self.listen(at: 3000, artist: "Nobody Local", title: "Unknown Song"),
        ])

        let summary = try await repo.rematch()
        #expect(summary.newlyMatched == 2)
        #expect(summary.overlapRemoved == 0)

        let linked = try await db.read { db in
            try ImportedListen.order(sql: "played_at").fetchAll(db)
        }
        #expect(linked[0].trackID == byName, "case and whitespace must not defeat the match")
        #expect(linked[1].trackID == byMbid, "the MusicBrainz id must win over the mismatched name")
        #expect(linked[2].trackID == nil, "music not in the library stays unmatched, not dropped")

        let counts = try await repo.counts()
        #expect(counts.matched == 2)
        #expect(counts.unmatched == 1)
    }

    @Test("Rematch survives typography and edition suffixes (tiers two and three)")
    func rematchTiers() async throws {
        let db = try await makeDB()
        let repo = ListenImportRepository(database: db)
        // The shapes measured on a real export: curly apostrophes in the
        // library rip, remaster/edit suffixes on the scrobble, and a suffix
        // on the library side instead.
        let curly = try await self.seedTrack(db, artistName: "Adele", title: "Don\u{2019}t You Remember")
        let plain = try await self.seedTrack(db, artistName: "Alanis Morissette", title: "You Learn")
        let live = try await self.seedTrack(db, artistName: "Wade Bowen", title: "Saturday Night")
        let libSuffix = try await self.seedTrack(db, artistName: "Avicii", title: "Levels - Radio Edit")

        _ = try await repo.insert([
            self.listen(at: 1000, artist: "Adele", title: "Don't You Remember"),
            self.listen(at: 2000, artist: "Alanis Morissette", title: "You Learn - 2015 Remaster"),
            self.listen(at: 3000, artist: "Wade Bowen", title: "Saturday Night (Live)"),
            self.listen(at: 4000, artist: "Avicii", title: "Levels"),
            self.listen(at: 5000, artist: "Adele", title: "Someone Like You"),
        ])

        let summary = try await repo.rematch()
        #expect(summary.newlyMatched == 4)
        let rows = try await db.read { db in
            try ImportedListen.order(sql: "played_at").fetchAll(db)
        }
        #expect(rows[0].trackID == curly, "straight versus curly apostrophes must not defeat the match")
        #expect(rows[1].trackID == plain, "a remaster suffix on the scrobble must be stripped")
        #expect(rows[2].trackID == live, "a live qualifier still credits the song for history purposes")
        #expect(rows[3].trackID == libSuffix, "a suffix on the library side must be stripped too")
        #expect(rows[4].trackID == nil, "a genuinely absent song must stay unmatched")
    }

    @Test("A matched listen inside the overlap window of a local play is dropped")
    func overlapWithLocalPlayIsRemoved() async throws {
        let db = try await makeDB()
        let repo = ListenImportRepository(database: db)
        let trackID = try await self.seedTrack(db, artistName: "Wade Bowen", title: "Turpentine")
        try await db.write { db in
            try db.execute(
                sql: "INSERT INTO play_history (track_id, played_at, duration_played, source) VALUES (?, ?, ?, ?)",
                arguments: [trackID, 5000, 180, "queue"]
            )
        }

        _ = try await repo.insert([
            self.listen(at: 5100, artist: "Wade Bowen", title: "Turpentine"),
            self.listen(at: 90000, artist: "Wade Bowen", title: "Turpentine"),
        ])

        let summary = try await repo.rematch()
        #expect(summary.newlyMatched == 2)
        #expect(summary.overlapRemoved == 1, "the scrobble echo of the local play must be dropped")
        let counts = try await repo.counts()
        #expect(counts.total == 1)
        #expect(counts.matched == 1)
    }

    @Test("removeAll is the one-statement undo")
    func removeAllUndoes() async throws {
        let db = try await makeDB()
        let repo = ListenImportRepository(database: db)
        _ = try await repo.insert([
            self.listen(at: 1000, artist: "A1", title: "T1"),
            self.listen(at: 2000, artist: "A2", title: "T2"),
        ])
        #expect(try await repo.removeAll() == 2)
        let counts = try await repo.counts()
        #expect(counts.total == 0)
    }
}
