import Foundation
import Observability

// MARK: - ScrobbleQueueWorker

/// Per-provider drain loop. Wakes on:
///   - explicit `kick()` from the recorder when a play is enqueued,
///   - reachability flipping from offline → online,
///   - app launch (one-shot drain),
///   - a sleep-until expiring after a transient failure.
///
/// Drain loop:
///   1. fetchPending (≤ 50)
///   2. submit → results
///   3. for each result: success → markSucceeded
///                       retry   → schedule next attempt with backoff
///                       permanent → markDead (or markDead via retry exhaustion)
///   4. if more pending exist, loop. Otherwise sleep until kicked.
public actor ScrobbleQueueWorker {
    private let provider: any ScrobbleProvider
    private let repo: ScrobbleQueueRepository
    private let policy: RetryPolicy
    private let reachability: any Reachability
    private let log: AppLogger
    private let now: @Sendable () -> Date
    private let batchSize: Int

    private var task: Task<Void, Never>?
    private var kickCount = 0
    private var kickContinuation: CheckedContinuation<Void, Never>?

    public init(
        provider: any ScrobbleProvider,
        repository: ScrobbleQueueRepository,
        policy: RetryPolicy = .default,
        reachability: any Reachability,
        batchSize: Int = 50,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.repo = repository
        self.policy = policy
        self.reachability = reachability
        self.batchSize = batchSize
        self.now = now
        self.log = AppLogger.make(.scrobble)
    }

    public func start() {
        guard self.task == nil else { return }
        self.log.info("scrobble.worker.start", ["provider": self.provider.id])
        self.task = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        self.task?.cancel()
        self.task = nil
        self.kickContinuation?.resume()
        self.kickContinuation = nil
    }

    /// External signal that there might be new work to drain.
    public func kick() {
        self.kickCount += 1
        if let cont = kickContinuation {
            self.kickContinuation = nil
            cont.resume()
        }
    }

    // MARK: Run loop

    private func run() async {
        // Subscribe to reachability changes — kick when we come back online.
        let reachStream = await self.reachability.updates()
        Task { [weak self] in
            for await reachable in reachStream {
                guard let self else { return }
                if reachable { await self.kick() }
            }
        }

        while !Task.isCancelled {
            let reachable = await self.reachability.currentlyReachable()
            if !reachable {
                self.log.debug("scrobble.worker.offline", ["provider": self.provider.id])
                await self.waitForKick(timeout: .seconds(60))
                continue
            }

            let authed = await self.provider.isAuthenticated()
            if !authed {
                await self.waitForKick(timeout: .seconds(60))
                continue
            }

            let pending: [ScrobbleQueueRepository.PendingRow]
            do {
                pending = try await self.repo.fetchPending(providerID: self.provider.id, limit: self.batchSize, now: self.now())
            } catch {
                self.log.error("scrobble.worker.fetch.fail", ["err": String(reflecting: error)])
                await self.waitForKick(timeout: .seconds(30))
                continue
            }

            if pending.isEmpty {
                await self.waitForKick(timeout: nil)
                continue
            }

            await self.process(pending)
        }
    }

    private func process(_ rows: [ScrobbleQueueRepository.PendingRow]) async {
        let started = self.now()
        let plays = rows.map { row in
            PlayEvent(
                queueID: row.queueID,
                trackID: row.trackID,
                artist: row.artist,
                albumArtist: row.albumArtist,
                album: row.album,
                title: row.title,
                duration: row.duration,
                mbid: row.mbid,
                playedAt: row.playedAt
            )
        }

        let results: [SubmissionResult]
        do {
            results = try await self.provider.submit(plays)
        } catch ScrobbleError.notAuthenticated {
            self.log.warning("scrobble.worker.unauth", ["provider": self.provider.id])
            return
        } catch ScrobbleError.invalidCredentials {
            self.log.warning("scrobble.worker.invalid_creds", ["provider": self.provider.id])
            return
        } catch let ScrobbleError.transient(_, reason, retryAfter) {
            await self.scheduleRetry(rows: rows, reason: reason, retryAfter: retryAfter)
            return
        } catch {
            self.log.error("scrobble.worker.submit.fail", ["err": String(reflecting: error)])
            await self.scheduleRetry(rows: rows, reason: String(reflecting: error), retryAfter: nil)
            return
        }

        // Match results back to rows by queueID for safety.
        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.queueID, $0) })
        for row in rows {
            guard let result = byID[row.queueID] else { continue }
            await self.apply(result, for: row)
        }
        self.log.debug("scrobble.worker.batch.done", [
            "provider": self.provider.id,
            "count": rows.count,
            "elapsed_ms": Int(self.now().timeIntervalSince(started) * 1000),
        ])
    }

    private func apply(_ result: SubmissionResult, for row: ScrobbleQueueRepository.PendingRow) async {
        do {
            switch result.outcome {
            case .success:
                try await self.repo.markSucceeded(queueID: result.queueID, providerID: self.provider.id, at: self.now())
            case let .ignored(reason):
                try await self.repo.markIgnored(queueID: result.queueID, providerID: self.provider.id, reason: reason)
            case let .retry(reason, after):
                let attempts = row.attempts + 1
                if self.policy.isExhausted(attempts: attempts) {
                    try await self.repo.markDead(
                        queueID: result.queueID,
                        providerID: self.provider.id,
                        reason: "retries exhausted: \(reason)"
                    )
                } else {
                    let delay = after ?? self.policy.delay(forAttempt: attempts + 1)
                    let next = self.now().addingTimeInterval(delay)
                    try await self.repo.markRetry(
                        queueID: result.queueID,
                        providerID: self.provider.id,
                        nextAttemptAt: next,
                        attempts: attempts,
                        reason: reason
                    )
                }
            case let .permanentFailure(reason):
                try await self.repo.markDead(queueID: result.queueID, providerID: self.provider.id, reason: reason)
            }
        } catch {
            self.log.error("scrobble.worker.apply.fail", ["err": String(reflecting: error)])
        }
    }

    private func scheduleRetry(rows: [ScrobbleQueueRepository.PendingRow], reason: String, retryAfter: TimeInterval?) async {
        for row in rows {
            let attempts = row.attempts + 1
            do {
                if self.policy.isExhausted(attempts: attempts) {
                    try await self.repo.markDead(queueID: row.queueID, providerID: self.provider.id, reason: "retries exhausted: \(reason)")
                } else {
                    let delay = retryAfter ?? self.policy.delay(forAttempt: attempts + 1)
                    let next = self.now().addingTimeInterval(delay)
                    try await self.repo.markRetry(
                        queueID: row.queueID,
                        providerID: self.provider.id,
                        nextAttemptAt: next,
                        attempts: attempts,
                        reason: reason
                    )
                }
            } catch {
                self.log.error("scrobble.worker.retry.persist.fail", ["err": String(reflecting: error)])
            }
        }
        // Sleep at least until the soonest scheduled attempt.
        let sleepFor = retryAfter ?? min(self.policy.maxDelay, self.policy.baseDelay)
        await self.waitForKick(timeout: .seconds(sleepFor))
    }

    /// Suspend until either a `kick()` arrives or `timeout` elapses (`nil` = forever).
    private func waitForKick(timeout: Duration?) async {
        if self.kickCount > 0 {
            self.kickCount = 0
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.kickContinuation = cont
            if let timeout {
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.timeoutKick()
                }
            }
        }
        self.kickCount = 0
    }

    private func timeoutKick() {
        if let cont = kickContinuation {
            self.kickContinuation = nil
            cont.resume()
        }
    }
}
