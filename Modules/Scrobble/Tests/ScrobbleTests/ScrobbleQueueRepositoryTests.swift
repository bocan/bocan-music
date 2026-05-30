import Foundation
import Persistence
import Testing
@testable import Scrobble

@Suite("ScrobbleQueueRepository", .serialized)
struct ScrobbleQueueRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func seedTrack(_ db: Database, id: Int64 = 1, title: String = "Song", artist: String = "Artist") async throws {
        try await db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO artists (id, name) VALUES (?, ?)", arguments: [id, artist])
            try db.execute(sql: """
            INSERT INTO tracks (id, file_url, title, artist_id, duration, added_at, updated_at)
            VALUES (?, ?, ?, ?, ?, 0, 0)
            """, arguments: [id, "/tmp/song-\(id).flac", title, id, 240.0])
        }
    }

    @Test("enqueue creates queue + submission rows")
    func enqueueSeedsRows() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db)
        let repo = ScrobbleQueueRepository(database: db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let qid = try await repo.enqueue(trackID: 1, playedAt: now, durationPlayed: 200, providerIDs: ["lastfm", "listenbrainz"])
        #expect(qid != nil)
        let pending = try await repo.fetchPending(providerID: "lastfm", now: now)
        #expect(pending.count == 1)
        #expect(pending.first?.title == "Song")
    }

    @Test("enqueue is idempotent on (track_id, played_at)")
    func enqueueIdempotent() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db)
        let repo = ScrobbleQueueRepository(database: db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let q1 = try await repo.enqueue(trackID: 1, playedAt: now, durationPlayed: 200, providerIDs: ["lastfm"])
        let q2 = try await repo.enqueue(trackID: 1, playedAt: now, durationPlayed: 200, providerIDs: ["lastfm"])
        #expect(q1 == q2)
    }

    @Test("markSucceeded flips queue.submitted when all providers done")
    func successFlipsSubmittedFlag() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db)
        let repo = ScrobbleQueueRepository(database: db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let qid = try try await #require(repo.enqueue(
            trackID: 1,
            playedAt: now,
            durationPlayed: 200,
            providerIDs: ["lastfm", "listenbrainz"]
        ))
        try await repo.markSucceeded(queueID: qid, providerID: "lastfm")
        let stats1 = try await repo.stats()
        #expect(stats1.pending == 1) // still pending: listenbrainz outstanding

        try await repo.markSucceeded(queueID: qid, providerID: "listenbrainz")
        let stats2 = try await repo.stats()
        #expect(stats2.pending == 0)
    }

    @Test("markSentUnconfirmed is terminal: excluded from pending, counts as submitted (#292)")
    func sentUnconfirmedIsTerminal() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db)
        let repo = ScrobbleQueueRepository(database: db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let qid = try try await #require(repo.enqueue(
            trackID: 1, playedAt: now, durationPlayed: 200, providerIDs: ["lastfm"]
        ))
        try await repo.markSentUnconfirmed(queueID: qid, providerID: "lastfm", reason: "confirm failed", at: now)

        // Not re-fetched for submission.
        let pending = try await repo.fetchPending(providerID: "lastfm", now: now)
        #expect(pending.isEmpty, "sent_unconfirmed rows must not be re-submitted")

        // Counted as done: queue no longer pending, and submittedToday includes it.
        let stats = try await repo.stats(now: now)
        #expect(stats.pending == 0)
        #expect(stats.submittedToday == 1)

        // reviveDead (which only touches 'failed') must not resurrect it.
        try await repo.reviveDead()
        let afterRevive = try await repo.fetchPending(providerID: "lastfm", now: now)
        #expect(afterRevive.isEmpty, "reviveDead must not resurrect sent_unconfirmed rows")
    }

    @Test("markRetry hides row until next_attempt_at")
    func retryDelaysFetch() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db)
        let repo = ScrobbleQueueRepository(database: db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let qid = try try await #require(repo.enqueue(trackID: 1, playedAt: now, durationPlayed: 200, providerIDs: ["lastfm"]))
        try await repo.markRetry(queueID: qid, providerID: "lastfm", nextAttemptAt: now.addingTimeInterval(120), attempts: 1, reason: "5xx")

        let earlyPending = try await repo.fetchPending(providerID: "lastfm", now: now.addingTimeInterval(60))
        #expect(earlyPending.isEmpty)
        let latePending = try await repo.fetchPending(providerID: "lastfm", now: now.addingTimeInterval(200))
        #expect(latePending.count == 1)
        #expect(latePending.first?.attempts == 1)
    }

    @Test("markDead hides row + sets queue dead when no providers alive")
    func deadLetterFlow() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db)
        let repo = ScrobbleQueueRepository(database: db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let qid = try try await #require(repo.enqueue(trackID: 1, playedAt: now, durationPlayed: 200, providerIDs: ["lastfm"]))
        try await repo.markDead(queueID: qid, providerID: "lastfm", reason: "exhausted")
        let stats = try await repo.stats()
        #expect(stats.pending == 0)
        #expect(stats.dead == 1)
    }

    @Test("reviveDead restores dead rows to pending")
    func revive() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db)
        let repo = ScrobbleQueueRepository(database: db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let qid = try try await #require(repo.enqueue(trackID: 1, playedAt: now, durationPlayed: 200, providerIDs: ["lastfm"]))
        try await repo.markDead(queueID: qid, providerID: "lastfm", reason: "x")
        try await repo.reviveDead()
        let pending = try await repo.fetchPending(providerID: "lastfm", now: now)
        #expect(pending.count == 1)
    }

    @Test("purgeDead deletes dead rows")
    func purge() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db)
        let repo = ScrobbleQueueRepository(database: db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let qid = try try await #require(repo.enqueue(trackID: 1, playedAt: now, durationPlayed: 200, providerIDs: ["lastfm"]))
        try await repo.markDead(queueID: qid, providerID: "lastfm", reason: "x")
        try await repo.purgeDead()
        let stats = try await repo.stats()
        #expect(stats.dead == 0)
    }

    @Test("fetchTrackMetadata returns row with joined artist/album names")
    func fetchTrackMetadataLookup() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db, id: 7, title: "Helix", artist: "Aphex")
        let repo = ScrobbleQueueRepository(database: db)
        let row = try await repo.fetchTrackMetadata(trackID: 7)
        let unwrapped = try #require(row)
        #expect(unwrapped.title == "Helix")
        #expect(unwrapped.artist == "Aphex")
        #expect(unwrapped.duration == 240.0)
        #expect(unwrapped.trackID == 7)
    }

    @Test("fetchTrackMetadata returns nil for missing track")
    func fetchTrackMetadataMissing() async throws {
        let db = try await self.makeDB()
        let repo = ScrobbleQueueRepository(database: db)
        let row = try await repo.fetchTrackMetadata(trackID: 999)
        #expect(row == nil)
    }

    @Test("enqueueSubsonic round-trips identity + payload through fetchPending")
    func subsonicRoundTrip() async throws {
        let db = try await self.makeDB()
        let repo = ScrobbleQueueRepository(database: db)
        let server = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let qid = try await repo.enqueueSubsonic(
            serverID: server,
            songID: "song-42",
            playedAt: now,
            durationPlayed: 200,
            title: "Faded",
            artist: "Alan Walker",
            album: "Different World",
            albumArtist: nil,
            duration: 212,
            providerIDs: ["subsonic", "listenbrainz"]
        )
        #expect(qid != nil)

        let pending = try await repo.fetchPending(providerID: "subsonic", now: now)
        #expect(pending.count == 1)
        let row = try #require(pending.first)
        #expect(row.trackID == -1)
        #expect(row.title == "Faded")
        #expect(row.artist == "Alan Walker")
        #expect(row.album == "Different World")
        #expect(row.duration == 212)
        #expect(row.subsonicServerID == server)
        #expect(row.subsonicSongID == "song-42")
    }

    @Test("fetchRecent includes Subsonic-sourced rows via payload fallback (#291)")
    func recentIncludesSubsonicRows() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db, id: 1, title: "Local Song", artist: "Local Artist")
        let repo = ScrobbleQueueRepository(database: db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // A local-track scrobble (track_id present).
        _ = try await repo.enqueue(
            trackID: 1,
            playedAt: now,
            durationPlayed: 200,
            providerIDs: ["lastfm"]
        )
        // A Subsonic-sourced scrobble (track_id IS NULL; metadata in payload_*).
        _ = try await repo.enqueueSubsonic(
            serverID: UUID(),
            songID: "song-99",
            playedAt: now.addingTimeInterval(60),
            durationPlayed: 200,
            title: "Streamed Song",
            artist: "Streamed Artist",
            album: "Streamed Album",
            albumArtist: nil,
            duration: 212,
            providerIDs: ["subsonic"]
        )

        let recent = try await repo.fetchRecent(limit: 50)
        #expect(recent.count == 2, "expected both local and Subsonic rows, got \(recent.count)")

        let subsonic = try #require(
            recent.first { $0.title == "Streamed Song" },
            "Subsonic-sourced row missing from fetchRecent (INNER JOIN regression)"
        )
        #expect(subsonic.artist == "Streamed Artist")
        #expect(subsonic.album == "Streamed Album")

        let local = try #require(recent.first { $0.title == "Local Song" })
        #expect(local.artist == "Local Artist")
    }

    @Test("enqueueSubsonic is idempotent on (serverID, songID, playedAt)")
    func subsonicEnqueueIdempotent() async throws {
        let db = try await self.makeDB()
        let repo = ScrobbleQueueRepository(database: db)
        let server = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await repo.enqueueSubsonic(
            serverID: server, songID: "s",
            playedAt: now, durationPlayed: 100,
            title: "T", artist: "A", album: nil, albumArtist: nil,
            duration: 200, providerIDs: ["subsonic"]
        )
        let second = try await repo.enqueueSubsonic(
            serverID: server, songID: "s",
            playedAt: now, durationPlayed: 100,
            title: "T", artist: "A", album: nil, albumArtist: nil,
            duration: 200, providerIDs: ["subsonic"]
        )
        #expect(first == second)
        let pending = try await repo.fetchPending(providerID: "subsonic", now: now)
        #expect(pending.count == 1)
    }
}
