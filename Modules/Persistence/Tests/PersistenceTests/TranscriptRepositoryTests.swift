import Foundation
import Testing
@testable import Persistence

@Suite("TranscriptRepository", .serialized)
struct TranscriptRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makePodcast(_ db: Database) async throws -> Int64 {
        let repo = PodcastRepository(database: db)
        return try await repo.insert(
            Podcast(feedURL: "https://example.test/feed", title: "Show", addedAt: 1_700_000_000)
        )
    }

    private func sampleTranscript(
        podcastID: Int64,
        guid: String,
        fetchedAt: Double = 1_700_000_000
    ) -> PodcastTranscript {
        PodcastTranscript(
            podcastID: podcastID,
            guid: guid,
            content: "WEBVTT\n\n00:00.000 --> 00:01.000\nHello",
            format: .vtt,
            language: "en",
            sourceURL: "https://example.test/\(guid).vtt",
            fetchedAt: fetchedAt
        )
    }

    @Test("every column round-trips through the hand-written upsert and an update replaces all of them (#421)")
    func upsertCarriesEveryColumn() async throws {
        let db = try await makeDB()
        let podcastID = try await makePodcast(db)
        let repo = TranscriptRepository(database: db)
        let first = PodcastTranscript(
            podcastID: podcastID,
            guid: "g",
            content: "1\n00:00:00,000 --> 00:00:01,000\nHi",
            format: .srt,
            language: "cy",
            sourceURL: "https://example.test/g.srt",
            fetchedAt: 1
        )
        try await repo.upsert(first)
        var stored = try #require(try await repo.fetch(podcastID: podcastID, guid: "g"))
        #expect(stored.content == first.content)
        #expect(stored.format == .srt)
        #expect(stored.language == "cy")
        #expect(stored.sourceURL == first.sourceURL)
        #expect(stored.fetchedAt == 1)

        let second = PodcastTranscript(
            podcastID: podcastID,
            guid: "g",
            content: "{\"segments\":[]}",
            format: .json,
            language: nil,
            sourceURL: "https://example.test/g.json",
            fetchedAt: 2
        )
        try await repo.upsert(second)
        stored = try #require(try await repo.fetch(podcastID: podcastID, guid: "g"))
        #expect(stored.content == second.content)
        #expect(stored.format == .json)
        #expect(stored.language == nil, "an explicit nil replaces the old language")
        #expect(stored.sourceURL == second.sourceURL)
        #expect(stored.fetchedAt == 2)
    }

    @Test("fetch returns nil on a miss")
    func fetchMiss() async throws {
        let db = try await makeDB()
        let repo = TranscriptRepository(database: db)
        let result = try await repo.fetch(podcastID: 1, guid: "x")
        #expect(result == nil)
    }

    @Test("upsert then fetch round-trips content, format, and language")
    func upsertRoundTrip() async throws {
        let db = try await makeDB()
        let pid = try await makePodcast(db)
        let repo = TranscriptRepository(database: db)
        try await repo.upsert(self.sampleTranscript(podcastID: pid, guid: "ep1"))
        let row = try await repo.fetch(podcastID: pid, guid: "ep1")
        let fetched = try #require(row)
        #expect(fetched.format == .vtt)
        #expect(fetched.language == "en")
        #expect(fetched.content.contains("Hello"))
        #expect(fetched.sourceURL == "https://example.test/ep1.vtt")
    }

    @Test("upsert replaces the row on the composite key")
    func upsertReplaces() async throws {
        let db = try await makeDB()
        let pid = try await makePodcast(db)
        let repo = TranscriptRepository(database: db)
        try await repo.upsert(self.sampleTranscript(podcastID: pid, guid: "ep1", fetchedAt: 100))
        var updated = self.sampleTranscript(podcastID: pid, guid: "ep1", fetchedAt: 200)
        updated.content = "Updated body"
        updated.format = .plain
        try await repo.upsert(updated)
        let row = try await repo.fetch(podcastID: pid, guid: "ep1")
        let fetched = try #require(row)
        #expect(fetched.content == "Updated body")
        #expect(fetched.format == .plain)
        #expect(fetched.fetchedAt == 200)
    }

    @Test("cleanup deletes only played transcripts older than the cutoff")
    func cleanupPlayedOlderThanCutoff() async throws {
        let db = try await makeDB()
        let pid = try await makePodcast(db)
        let transcripts = TranscriptRepository(database: db)
        let states = EpisodeStateRepository(database: db)

        let base = 2_000_000_000.0
        let day = 24.0 * 60 * 60

        for guid in ["old-played", "recent-played", "in-progress", "unplayed"] {
            try await transcripts.upsert(self.sampleTranscript(podcastID: pid, guid: guid))
        }
        // (a) played, clock 31 days old -> deleted.
        try await states.markPlayed(podcastID: pid, guid: "old-played", now: base - 31 * day)
        // (b) played, clock 29 days old -> kept.
        try await states.markPlayed(podcastID: pid, guid: "recent-played", now: base - 29 * day)
        // (c) in progress -> kept.
        try await states.savePosition(podcastID: pid, guid: "in-progress", position: 12, now: base - 40 * day)
        // (d) unplayed: no state row at all -> kept.

        let deleted = try await transcripts.deletePlayedOlderThan(cutoff: base - 30 * day)
        #expect(deleted == 1)

        let oldPlayed = try await transcripts.fetch(podcastID: pid, guid: "old-played")
        let recentPlayed = try await transcripts.fetch(podcastID: pid, guid: "recent-played")
        let inProgress = try await transcripts.fetch(podcastID: pid, guid: "in-progress")
        let unplayed = try await transcripts.fetch(podcastID: pid, guid: "unplayed")
        #expect(oldPlayed == nil)
        #expect(recentPlayed != nil)
        #expect(inProgress != nil)
        #expect(unplayed != nil)
    }
}
