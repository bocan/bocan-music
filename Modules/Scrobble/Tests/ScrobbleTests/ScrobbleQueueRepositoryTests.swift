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
}
