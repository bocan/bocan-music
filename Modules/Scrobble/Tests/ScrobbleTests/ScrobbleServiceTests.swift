import Foundation
import Persistence
import Playback
import Testing
@testable import Scrobble

@Suite("ScrobbleService", .serialized)
struct ScrobbleServiceTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func seedTrack(_ db: Database, id: Int64 = 1) async throws {
        try await db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO artists (id, name) VALUES (1, 'Artist')")
            try db.execute(sql: """
            INSERT INTO tracks (id, file_url, title, artist_id, duration, added_at, updated_at)
            VALUES (?, ?, 'Song', 1, 240.0, 0, 0)
            """, arguments: [id, "/tmp/\(id).flac"])
        }
    }

    private func makeService(
        providers: [any ScrobbleProvider],
        repo: ScrobbleQueueRepository
    ) -> ScrobbleService {
        ScrobbleService(
            providers: providers,
            repository: repo,
            reachability: StaticReachability(reachable: true),
            policy: RetryPolicy(baseDelay: 0.01, maxDelay: 0.05, maxAttempts: 2, jitter: 0)
        )
    }

    // MARK: - recordPlay

    @Test("recordPlay enqueues when at least one provider is authenticated")
    func recordPlayEnqueues() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db)
        let repo = ScrobbleQueueRepository(database: db)
        let provider = SpyProvider(id: "alpha", authenticated: true)
        let service = self.makeService(providers: [provider], repo: repo)
        await service.recordPlay(trackID: 1, playedAt: Date(), durationPlayed: 200)
        let stats = try await repo.stats()
        #expect(stats.pending == 1)
    }

    @Test("recordPlay skips when no providers are authenticated")
    func recordPlaySkipsWhenNoAuth() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db)
        let repo = ScrobbleQueueRepository(database: db)
        let provider = SpyProvider(id: "alpha", authenticated: false)
        let service = self.makeService(providers: [provider], repo: repo)
        await service.recordPlay(trackID: 1, playedAt: Date(), durationPlayed: 200)
        let stats = try await repo.stats()
        #expect(stats.pending == 0)
    }

    @Test("recordPlay skips when played_at is outside backdate window")
    func recordPlaySkipsBackdated() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db)
        let repo = ScrobbleQueueRepository(database: db)
        let provider = SpyProvider(id: "alpha", authenticated: true)
        let service = self.makeService(providers: [provider], repo: repo)
        let ancient = Date().addingTimeInterval(-60 * 60 * 24 * 365)
        await service.recordPlay(trackID: 1, playedAt: ancient, durationPlayed: 200)
        let stats = try await repo.stats()
        #expect(stats.pending == 0)
    }

    // MARK: - nowPlaying

    @Test("nowPlaying(metadata) dispatches to all authenticated providers")
    func nowPlayingDirectDispatches() async throws {
        let db = try await self.makeDB()
        let repo = ScrobbleQueueRepository(database: db)
        let p1 = SpyProvider(id: "alpha", authenticated: true)
        let p2 = SpyProvider(id: "beta", authenticated: false)
        let service = self.makeService(providers: [p1, p2], repo: repo)
        await service.nowPlaying(
            trackID: 1,
            artist: "A",
            albumArtist: nil,
            album: nil,
            title: "T",
            duration: 240,
            mbid: nil
        )
        #expect(await p1.nowPlayingCalls == 1)
        #expect(await p2.nowPlayingCalls == 0)
    }

    @Test("nowPlaying(trackID) loads metadata from repository and dispatches")
    func nowPlayingByTrackID() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db)
        let repo = ScrobbleQueueRepository(database: db)
        let provider = SpyProvider(id: "alpha", authenticated: true)
        let service = self.makeService(providers: [provider], repo: repo)
        await service.nowPlaying(trackID: 1)
        #expect(await provider.nowPlayingCalls == 1)
    }

    @Test("nowPlaying(trackID) silently skips when track row is missing")
    func nowPlayingMissingTrack() async throws {
        let db = try await self.makeDB()
        let repo = ScrobbleQueueRepository(database: db)
        let provider = SpyProvider(id: "alpha", authenticated: true)
        let service = self.makeService(providers: [provider], repo: repo)
        await service.nowPlaying(trackID: 999)
        #expect(await provider.nowPlayingCalls == 0)
    }

    @Test("nowPlaying(trackID) is a no-op when no providers are authenticated")
    func nowPlayingNoAuth() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db)
        let repo = ScrobbleQueueRepository(database: db)
        let provider = SpyProvider(id: "alpha", authenticated: false)
        let service = self.makeService(providers: [provider], repo: repo)
        await service.nowPlaying(trackID: 1)
        #expect(await provider.nowPlayingCalls == 0)
    }

    // MARK: - Subsonic paths

    @Test("recordSubsonicPlay enqueues a subsonic row")
    func recordSubsonic() async throws {
        let db = try await self.makeDB()
        let repo = ScrobbleQueueRepository(database: db)
        let provider = SpyProvider(id: "alpha", authenticated: true)
        let service = self.makeService(providers: [provider], repo: repo)
        let ctx = SubsonicPlayContext(
            serverID: UUID(),
            songID: "abc",
            title: "Title",
            artist: "Artist",
            duration: 200
        )
        await service.recordSubsonicPlay(context: ctx, playedAt: Date(), durationPlayed: 180)
        let stats = try await repo.stats()
        #expect(stats.pending == 1)
    }

    @Test("recordSubsonicPlay skips when no providers are authenticated")
    func recordSubsonicNoAuth() async throws {
        let db = try await self.makeDB()
        let repo = ScrobbleQueueRepository(database: db)
        let provider = SpyProvider(id: "alpha", authenticated: false)
        let service = self.makeService(providers: [provider], repo: repo)
        let ctx = SubsonicPlayContext(
            serverID: UUID(), songID: "abc", title: "T", artist: "A", duration: 200
        )
        await service.recordSubsonicPlay(context: ctx, playedAt: Date(), durationPlayed: 180)
        let stats = try await repo.stats()
        #expect(stats.pending == 0)
    }

    @Test("nowPlayingSubsonic dispatches to authenticated providers")
    func nowPlayingSubsonicDispatches() async throws {
        let db = try await self.makeDB()
        let repo = ScrobbleQueueRepository(database: db)
        let provider = SpyProvider(id: "alpha", authenticated: true)
        let service = self.makeService(providers: [provider], repo: repo)
        let ctx = SubsonicPlayContext(
            serverID: UUID(), songID: "abc", title: "T", artist: "A", duration: 200
        )
        await service.nowPlayingSubsonic(context: ctx)
        #expect(await provider.nowPlayingCalls == 1)
    }

    // MARK: - love

    @Test("love(track:) dispatches to authenticated providers only")
    func loveDispatch() async throws {
        let db = try await self.makeDB()
        let repo = ScrobbleQueueRepository(database: db)
        let p1 = SpyProvider(id: "alpha", authenticated: true)
        let p2 = SpyProvider(id: "beta", authenticated: false)
        let service = self.makeService(providers: [p1, p2], repo: repo)
        await service.love(track: TrackIdentity(artist: "A", title: "T"), loved: true)
        #expect(await p1.loveCalls == 1)
        #expect(await p2.loveCalls == 0)
    }

    @Test("love(trackID:) looks up metadata and dispatches")
    func loveByTrackID() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db)
        let repo = ScrobbleQueueRepository(database: db)
        let provider = SpyProvider(id: "alpha", authenticated: true)
        let service = self.makeService(providers: [provider], repo: repo)
        await service.love(trackID: 1, loved: false)
        #expect(await provider.loveCalls == 1)
    }

    @Test("love(trackID:) skips silently for missing track row")
    func loveMissingTrack() async throws {
        let db = try await self.makeDB()
        let repo = ScrobbleQueueRepository(database: db)
        let provider = SpyProvider(id: "alpha", authenticated: true)
        let service = self.makeService(providers: [provider], repo: repo)
        await service.love(trackID: 999, loved: true)
        #expect(await provider.loveCalls == 0)
    }

    @Test("love(trackID:) is a no-op when no providers are authenticated")
    func loveNoAuth() async throws {
        let db = try await self.makeDB()
        try await self.seedTrack(db)
        let repo = ScrobbleQueueRepository(database: db)
        let provider = SpyProvider(id: "alpha", authenticated: false)
        let service = self.makeService(providers: [provider], repo: repo)
        await service.love(trackID: 1, loved: true)
        #expect(await provider.loveCalls == 0)
    }

    // MARK: - Lifecycle & lookup

    @Test("start then stop is safe and provider lookup works")
    func startStopLookup() async throws {
        let db = try await self.makeDB()
        let repo = ScrobbleQueueRepository(database: db)
        let provider = SpyProvider(id: "alpha", authenticated: true)
        let service = self.makeService(providers: [provider], repo: repo)
        await service.start()
        await service.kickAll()
        await service.stop()

        let p = await service.provider(id: "alpha")
        #expect(p != nil)
        let missing = await service.provider(id: "missing")
        #expect(missing == nil)
        #expect(service.queueRepository === repo)
    }
}

// MARK: - Fixtures

private actor SpyProvider: ScrobbleProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    private let authenticated: Bool
    var submitCalls = 0
    var nowPlayingCalls = 0
    var loveCalls = 0

    init(id: String, authenticated: Bool) {
        self.id = id
        self.displayName = id
        self.authenticated = authenticated
    }

    func isAuthenticated() async -> Bool {
        self.authenticated
    }

    func nowPlaying(_: PlayEvent) async throws {
        self.nowPlayingCalls += 1
    }

    func submit(_ plays: [PlayEvent]) async throws -> [SubmissionResult] {
        self.submitCalls += 1
        return plays.map { SubmissionResult(queueID: $0.queueID, outcome: .success) }
    }

    func love(track _: TrackIdentity, loved _: Bool) async throws {
        self.loveCalls += 1
    }
}
