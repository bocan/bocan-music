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

    @Test("markSucceeded write failure does not re-submit the scrobble (#292)")
    func successConfirmWriteFailureNoDoubleSubmit() async throws {
        let db = try await self.makeDB()
        let repo = try await self.seedAndEnqueue(db, count: 1)

        // Install a trigger that aborts any attempt to set a submission row to
        // 'sent'. This simulates a persistence failure on the markSucceeded
        // write *after* the provider has already accepted the scrobble. The
        // sentinel write uses 'sent_unconfirmed', so the trigger lets it through.
        try await db.write { db in
            try db.execute(sql: """
            CREATE TRIGGER block_sent
            BEFORE UPDATE OF status ON scrobble_submissions
            WHEN NEW.status = 'sent'
            BEGIN
                SELECT RAISE(ABORT, 'simulated confirm-write failure');
            END
            """)
        }

        let provider = MockProvider()
        let worker = ScrobbleQueueWorker(
            provider: provider,
            repository: repo,
            policy: RetryPolicy(baseDelay: 0.01, maxDelay: 0.05, maxAttempts: 3, jitter: 0),
            reachability: StaticReachability(reachable: true)
        )
        await worker.start()
        await worker.kick()

        // The row should leave the pending set (via the sentinel) so stats settle.
        try await self.waitFor(timeout: 2.0) { try await repo.stats().pending == 0 }
        // Give the loop a moment to attempt any (incorrect) re-submission.
        try await Task.sleep(for: .milliseconds(200))
        await worker.stop()

        // The provider must have been called exactly once: the scrobble was
        // delivered, and the sentinel prevented a second submission.
        let calls = await provider.submitCalls
        #expect(calls == 1, "scrobble re-submitted \(calls) times; expected exactly 1")

        // The submission row is terminal (sent_unconfirmed), not pending/retry.
        let recent = try await repo.fetchRecent(limit: 10)
        let row = try #require(recent.first)
        #expect(row.statusByProvider["mock"] == .sentUnconfirmed)
    }

    @Test("reachability subscription task is cancelled when worker stops (#293)")
    func reachabilityTaskCancelledOnStop() async throws {
        let db = try await self.makeDB()
        let repo = try await self.seedAndEnqueue(db, count: 1)
        let reach = StaticReachability(reachable: true)
        let worker = ScrobbleQueueWorker(
            provider: MockProvider(),
            repository: repo,
            policy: RetryPolicy(baseDelay: 0.01, maxDelay: 0.05, maxAttempts: 3, jitter: 0),
            reachability: reach
        )
        await worker.start()
        try await Task.sleep(for: .milliseconds(50))
        await worker.stop()

        // Toggle reachability after stop — it should NOT trigger a kick that
        // causes another submit call. We verify no additional DB work happens.
        let statsBefore = try await repo.stats()
        await reach.set(false)
        await reach.set(true)
        try await Task.sleep(for: .milliseconds(100))
        let statsAfter = try await repo.stats()
        // If the reachability task were still alive it could trigger more drains;
        // the row count must be stable (already drained to 0 or still at 1).
        #expect(statsBefore.pending == statsAfter.pending, "reachability task fired after stop()")
    }

    // MARK: helpers

    // MARK: - Wait timers (#548)

    /// A worker with no queue behind it: these tests drive `waitForKick`
    /// directly, so nothing needs draining.
    private func makeBareWorker() async throws -> ScrobbleQueueWorker {
        try await ScrobbleQueueWorker(
            provider: MockProvider(),
            repository: ScrobbleQueueRepository(database: self.makeDB()),
            policy: RetryPolicy(baseDelay: 0.01, maxDelay: 0.05, maxAttempts: 3, jitter: 0),
            reachability: StaticReachability(reachable: true)
        )
    }

    /// Records when a wait finished, so a test can tell "still suspended" from
    /// "returned early".
    private actor Finished {
        private(set) var value = false

        func mark() {
            self.value = true
        }
    }

    @Test("a kick's cancelled timer does not cut short the next wait (#548)")
    func staleTimeoutDoesNotEndALaterWait() async throws {
        let worker = try await self.makeBareWorker()

        // First wait: a short timer, ended early by a kick. Before the fix its
        // timer stayed alive and fired about 200 ms later.
        let first = Finished()
        let firstWait = Task {
            await worker.waitForKick(timeout: .milliseconds(200))
            await first.mark()
        }
        try await Task.sleep(for: .milliseconds(50))
        await worker.kick()
        _ = await firstWait.value
        #expect(await first.value, "the kick ends the first wait")

        // Second wait: a long timer. The first wait's stale timer, if it
        // survived, lands inside this one and ends it early.
        let second = Finished()
        let secondWait = Task {
            await worker.waitForKick(timeout: .seconds(30))
            await second.mark()
        }
        defer { secondWait.cancel() }
        try await Task.sleep(for: .milliseconds(500))
        #expect(await !(second.value), "a backoff wait must not be cut short by an earlier timer")

        // It must still be endable on purpose.
        await worker.kick()
        _ = await secondWait.value
        #expect(await second.value)
    }

    @Test("a wait still ends on its own timeout")
    func ownTimeoutStillFires() async throws {
        let worker = try await self.makeBareWorker()
        let finished = Finished()
        let wait = Task {
            await worker.waitForKick(timeout: .milliseconds(100))
            await finished.mark()
        }
        _ = await wait.value
        #expect(await finished.value, "the timer this wait started must still end it")
    }

    @Test("stop() releases a wait and leaves no timer behind")
    func stopReleasesTheWait() async throws {
        let worker = try await self.makeBareWorker()
        let finished = Finished()
        let wait = Task {
            await worker.waitForKick(timeout: .seconds(30))
            await finished.mark()
        }
        try await Task.sleep(for: .milliseconds(100))
        await worker.stop()
        _ = await wait.value
        #expect(await finished.value)
    }

    private func waitFor(timeout: TimeInterval, predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() {
                return
            }
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
