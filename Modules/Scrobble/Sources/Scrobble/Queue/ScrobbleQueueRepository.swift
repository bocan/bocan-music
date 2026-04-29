import Foundation
import GRDB
import Observability
import Persistence

// MARK: - ScrobbleQueueRepository

/// Persistence-side adapter for the scrobble queue. Encapsulates every SQL
/// query the worker needs so the worker itself can stay focused on
/// scheduling/backoff and providers.
public actor ScrobbleQueueRepository {
    public struct PendingRow: Sendable, Hashable {
        public let queueID: Int64
        public let trackID: Int64
        public let playedAt: Date
        public let durationPlayed: TimeInterval
        public let attempts: Int
        public let nextAttemptAt: Date?

        public let title: String
        public let artist: String
        public let albumArtist: String?
        public let album: String?
        public let duration: TimeInterval
        public let mbid: String?
    }

    public struct Stats: Sendable, Equatable {
        public let pending: Int
        public let dead: Int
        public let submittedToday: Int
    }

    private let db: Persistence.Database

    public init(database: Persistence.Database) {
        self.db = database
    }

    /// Insert a freshly-completed play into `scrobble_queue` (idempotent on
    /// `(track_id, played_at)`) and create a `pending` row in
    /// `scrobble_submissions` for every active provider.
    @discardableResult
    public func enqueue(
        trackID: Int64,
        playedAt: Date,
        durationPlayed: TimeInterval,
        providerIDs: [String]
    ) async throws -> Int64? {
        try await self.db.write { db in
            try db.execute(sql: """
            INSERT OR IGNORE INTO scrobble_queue
              (track_id, played_at, duration_played, submitted, submission_attempts, dead)
            VALUES (?, ?, ?, 0, 0, 0)
            """, arguments: [trackID, Int(playedAt.timeIntervalSince1970), durationPlayed])
            let queueID: Int64? = try Int64.fetchOne(db, sql: """
            SELECT id FROM scrobble_queue WHERE track_id = ? AND played_at = ?
            """, arguments: [trackID, Int(playedAt.timeIntervalSince1970)])
            guard let queueID else { return nil }
            for pid in providerIDs {
                try db.execute(sql: """
                INSERT OR IGNORE INTO scrobble_submissions
                  (queue_id, provider_id, status, attempts)
                VALUES (?, ?, 'pending', 0)
                """, arguments: [queueID, pid])
            }
            return queueID
        }
    }

    /// Fetch up to `limit` rows ready for submission to `providerID`.
    public func fetchPending(providerID: String, limit: Int = 50, now: Date = Date()) async throws -> [PendingRow] {
        let nowEpoch = Int(now.timeIntervalSince1970)
        return try await self.db.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT q.id, q.track_id, q.played_at, q.duration_played,
                   s.attempts, s.next_attempt_at,
                   t.title, t.duration, t.musicbrainz_recording_id,
                   a.name AS artist_name,
                   aa.name AS album_artist_name,
                   al.title AS album_title
              FROM scrobble_submissions s
              JOIN scrobble_queue q ON q.id = s.queue_id
              JOIN tracks t ON t.id = q.track_id
              LEFT JOIN artists a ON a.id = t.artist_id
              LEFT JOIN artists aa ON aa.id = t.album_artist_id
              LEFT JOIN albums al ON al.id = t.album_id
             WHERE s.provider_id = ?
               AND s.status IN ('pending', 'retry')
               AND q.dead = 0
               AND (s.next_attempt_at IS NULL OR s.next_attempt_at <= ?)
             ORDER BY q.played_at ASC
             LIMIT ?
            """, arguments: [providerID, nowEpoch, limit])
            return rows.map { row in
                PendingRow(
                    queueID: row["id"],
                    trackID: row["track_id"],
                    playedAt: Date(timeIntervalSince1970: TimeInterval(row["played_at"] as Int)),
                    durationPlayed: row["duration_played"] ?? 0,
                    attempts: row["attempts"],
                    nextAttemptAt: (row["next_attempt_at"] as Int?).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    title: row["title"] ?? "",
                    artist: row["artist_name"] ?? "",
                    albumArtist: row["album_artist_name"],
                    album: row["album_title"],
                    duration: row["duration"] ?? 0,
                    mbid: row["musicbrainz_recording_id"]
                )
            }
        }
    }

    /// Mark a submission row succeeded (and the queue row submitted, if every provider succeeded).
    public func markSucceeded(queueID: Int64, providerID: String, at now: Date = Date()) async throws {
        let nowEpoch = Int(now.timeIntervalSince1970)
        try await self.db.write { db in
            try db.execute(sql: """
            UPDATE scrobble_submissions
               SET status = 'sent', submitted_at = ?, last_error = NULL
             WHERE queue_id = ? AND provider_id = ?
            """, arguments: [nowEpoch, queueID, providerID])
            // If every submission row for this queue_id is sent, mark the queue row submitted.
            let pending = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM scrobble_submissions
             WHERE queue_id = ? AND status NOT IN ('sent', 'ignored')
            """, arguments: [queueID]) ?? 0
            if pending == 0 {
                try db.execute(sql: "UPDATE scrobble_queue SET submitted = 1 WHERE id = ?", arguments: [queueID])
            }
        }
    }

    /// Increment `attempts` and schedule the next attempt.
    public func markRetry(
        queueID: Int64,
        providerID: String,
        nextAttemptAt: Date,
        attempts: Int,
        reason: String
    ) async throws {
        try await self.db.write { db in
            try db.execute(sql: """
            UPDATE scrobble_submissions
               SET status = 'retry',
                   attempts = ?,
                   next_attempt_at = ?,
                   last_error = ?
             WHERE queue_id = ? AND provider_id = ?
            """, arguments: [attempts, Int(nextAttemptAt.timeIntervalSince1970), reason, queueID, providerID])
            try db.execute(sql: """
            UPDATE scrobble_queue SET submission_attempts = ?, last_error = ? WHERE id = ?
            """, arguments: [attempts, reason, queueID])
        }
    }

    /// Mark a submission row dead (permanent failure or retry-exhausted).
    public func markDead(queueID: Int64, providerID: String, reason: String) async throws {
        try await self.db.write { db in
            try db.execute(sql: """
            UPDATE scrobble_submissions
               SET status = 'failed', last_error = ?
             WHERE queue_id = ? AND provider_id = ?
            """, arguments: [reason, queueID, providerID])
            // If every submission row for this queue is in a terminal state and at
            // least one is failed, we mark the queue row dead so the UI can surface it.
            let alive = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM scrobble_submissions
             WHERE queue_id = ? AND status IN ('pending', 'retry')
            """, arguments: [queueID]) ?? 0
            if alive == 0 {
                try db.execute(sql: """
                UPDATE scrobble_queue
                   SET dead = 1, last_error = ?
                 WHERE id = ? AND submitted = 0
                """, arguments: [reason, queueID])
            }
        }
    }

    /// Mark a submission row ignored (server accepted-but-skipped).
    public func markIgnored(queueID: Int64, providerID: String, reason: String) async throws {
        try await self.db.write { db in
            try db.execute(sql: """
            UPDATE scrobble_submissions
               SET status = 'ignored', last_error = ?
             WHERE queue_id = ? AND provider_id = ?
            """, arguments: [reason, queueID, providerID])
        }
    }

    /// Reset every dead row so the worker re-tries them. Used by "retry all" UI.
    public func reviveDead() async throws {
        try await self.db.write { db in
            try db.execute(sql: """
            UPDATE scrobble_submissions
               SET status = 'pending', attempts = 0, next_attempt_at = NULL, last_error = NULL
             WHERE status = 'failed'
            """)
            try db.execute(sql: """
            UPDATE scrobble_queue SET dead = 0, submission_attempts = 0, last_error = NULL
             WHERE dead = 1 AND submitted = 0
            """)
        }
    }

    /// Drop dead rows from the queue (delete forever).
    public func purgeDead() async throws {
        try await self.db.write { db in
            try db.execute(sql: "DELETE FROM scrobble_queue WHERE dead = 1 AND submitted = 0")
        }
    }

    /// Aggregate counts for the UI summary line.
    public func stats(now: Date = Date()) async throws -> Stats {
        try await self.db.read { db in
            let pending = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM scrobble_queue WHERE submitted = 0 AND dead = 0
            """) ?? 0
            let dead = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM scrobble_queue WHERE dead = 1
            """) ?? 0
            let calendar = Calendar(identifier: .gregorian)
            let startOfDay = calendar.startOfDay(for: now)
            let submittedToday = try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT queue_id) FROM scrobble_submissions
             WHERE status = 'sent' AND submitted_at >= ?
            """, arguments: [Int(startOfDay.timeIntervalSince1970)]) ?? 0
            return Stats(pending: pending, dead: dead, submittedToday: submittedToday)
        }
    }

    /// Stream live `Stats` for the UI.
    public nonisolated func observeStats() -> AsyncThrowingStream<Stats, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [database = self.db] in
                let upstream = await database.observe(value: { db -> Stats in
                    let pending = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM scrobble_queue WHERE submitted = 0 AND dead = 0
                    """) ?? 0
                    let dead = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM scrobble_queue WHERE dead = 1
                    """) ?? 0
                    let startOfDay = Calendar(identifier: .gregorian).startOfDay(for: Date())
                    let submittedToday = try Int.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT queue_id) FROM scrobble_submissions
                     WHERE status = 'sent' AND submitted_at >= ?
                    """, arguments: [Int(startOfDay.timeIntervalSince1970)]) ?? 0
                    return Stats(pending: pending, dead: dead, submittedToday: submittedToday)
                })
                do {
                    for try await value in upstream {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
