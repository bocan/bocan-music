import Foundation
import Persistence
import Testing
@testable import Scrobble

@Suite("ScrobbleQueueWorker", .serialized)
struct ScrobbleQueueWorkerTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func seedAndEnqueue(_ db: Database, count: Int = 3) async throws -> ScrobbleQueueRepository {
        try await db.write { db in
            try db.execute(sql: "INSERT INTO artists (id, name) VALUES (1, 'Artist')")
            for i in 1 ... count {
                try db.execute(sql: """
                INSERT INTO tracks (id, file_url, title, artist_id, duration, added_at, updated_at)
                VALUES (?, ?, ?, 1, 240.0, 0, 0)
                """, arguments: [Int64(i), "/tmp/\(i).flac", "Track \(i)"])
            }
        }
        let repo = ScrobbleQueueRepository(database: db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 1 ... count {
            _ = try await repo.enqueue(
                trackID: Int64(i),
                playedAt: now.addingTimeInterval(TimeInterval(i)),
                durationPlayed: 200,
                providerIDs: ["mock"]
            )
        }
        return repo
    }

    @Test("worker drains pending submissions on kick")
    func happyPath() async throws {
        let db = try await self.makeDB()
        let repo = try await self.seedAndEnqueue(db)
        let provider = MockProvider()
        let worker = ScrobbleQueueWorker(
            provider: provider,
            repository: repo,
            policy: RetryPolicy(baseDelay: 0.01, maxDelay: 0.05, maxAttempts: 3, jitter: 0),
            reachability: StaticReachability(reachable: true)
        )
        await worker.start()
        await worker.kick()

        try await self.waitFor(timeout: 2.0) { try await repo.stats().pending == 0 }
        let calls = await provider.submitCalls
        #expect(calls >= 1)
        await worker.stop()
    }

    @Test("worker pauses while offline and drains when reachable")
    func pausesWhileOffline() async throws {
        let db = try await self.makeDB()
        let repo = try await self.seedAndEnqueue(db, count: 2)
        let provider = MockProvider()
        let reach = StaticReachability(reachable: false)
        let worker = ScrobbleQueueWorker(
            provider: provider,
            repository: repo,
            policy: RetryPolicy(baseDelay: 0.01, maxDelay: 0.05, maxAttempts: 3, jitter: 0),
            reachability: reach
        )
        await worker.start()
        try await Task.sleep(for: .milliseconds(100))
        let stats1 = try await repo.stats()
        #expect(stats1.pending == 2) // still queued

        await reach.set(true)
        try await self.waitFor(timeout: 2.0) { try await repo.stats().pending == 0 }
        await worker.stop()
    }

    @Test("transient failure schedules retry, success on next pass")
    func retryThenSucceed() async throws {
        let db = try await self.makeDB()
        let repo = try await self.seedAndEnqueue(db, count: 1)
        let provider = MockProvider()
        await provider.queue([
            { plays in plays.map { SubmissionResult(queueID: $0.queueID, outcome: .retry(reason: "5xx", after: 0.01)) } },
            { plays in plays.map { SubmissionResult(queueID: $0.queueID, outcome: .success) } },
        ])
        let worker = ScrobbleQueueWorker(
            provider: provider,
            repository: repo,
            policy: RetryPolicy(baseDelay: 0.01, maxDelay: 0.05, maxAttempts: 5, jitter: 0),
            reachability: StaticReachability(reachable: true)
        )
        await worker.start()
        await worker.kick()
        try await self.waitFor(timeout: 3.0) { try await repo.stats().pending == 0 }
        await worker.stop()
    }

    @Test("permanent failure marks dead immediately")
    func permanentFailureMarksDead() async throws {
        let db = try await self.makeDB()
        let repo = try await self.seedAndEnqueue(db, count: 1)
        let provider = MockProvider()
        await provider.queue([{ plays in plays.map { SubmissionResult(queueID: $0.queueID, outcome: .permanentFailure(reason: "bad")) } }])
        let worker = ScrobbleQueueWorker(
            provider: provider, repository: repo,
            policy: RetryPolicy(baseDelay: 0.01, maxDelay: 0.02, maxAttempts: 3, jitter: 0),
            reachability: StaticReachability(reachable: true)
        )
        await worker.start()
        await worker.kick()
        try await self.waitFor(timeout: 2.0) { try await repo.stats().dead == 1 }
        await worker.stop()
    }

    // MARK: helpers

    private func waitFor(timeout: TimeInterval, predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("waitFor timed out after \(timeout)s")
    }
}

// MARK: - MockProvider

actor MockProvider: ScrobbleProvider {
    nonisolated let id = "mock"
    nonisolated let displayName = "Mock"
    var submitCalls = 0
    var nowPlayingCalls = 0
    var responses: [@Sendable ([PlayEvent]) -> [SubmissionResult]] = []

    func queue(_ responses: [@Sendable ([PlayEvent]) -> [SubmissionResult]]) {
        self.responses.append(contentsOf: responses)
    }

    func isAuthenticated() async -> Bool {
        true
    }

    func nowPlaying(_ play: PlayEvent) async throws {
        self.nowPlayingCalls += 1
    }

    func submit(_ plays: [PlayEvent]) async throws -> [SubmissionResult] {
        self.submitCalls += 1
        if let next = responses.first {
            self.responses.removeFirst()
            return next(plays)
        }
        return plays.map { SubmissionResult(queueID: $0.queueID, outcome: .success) }
    }

    func love(track: TrackIdentity, loved: Bool) async throws {}
}
