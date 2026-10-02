import Foundation
import GRDB
import Persistence

// MARK: - Recent scrobbles

/// The recent-scrobbles list and the live streams the UI observes.
public extension ScrobbleQueueRepository {
    /// Fetch the most recent `limit` scrobble-queue entries, optionally filtered to a single
    /// provider. Returns one `RecentRow` per queue entry with per-provider statuses attached.
    func fetchRecent(limit: Int = 50, providerID: String? = nil) async throws -> [RecentRow] {
        try await self.db.read { db in
            try Self.queryRecent(db: db, limit: limit, providerID: providerID)
        }
    }

    /// Live stream of recent scrobbles. Re-emits whenever `scrobble_queue` or
    /// `scrobble_submissions` change (e.g. a pending item becomes sent).
    nonisolated func observeRecent(limit: Int = 50, providerID: String? = nil) -> AsyncThrowingStream<[RecentRow], Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [database = self.db] in
                let upstream = await database.observe { db -> [RecentRow] in
                    try Self.queryRecent(db: db, limit: limit, providerID: providerID)
                }
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

    // MARK: - Private helpers

    /// Shared implementation for `fetchRecent` and `observeRecent`.
    private static func queryRecent(
        db: GRDB.Database,
        limit: Int,
        providerID: String?
    ) throws -> [RecentRow] {
        // Build the queue-row query, optionally restricting to a provider.
        // LEFT JOIN (not INNER) so Subsonic-sourced rows -- which have
        // track_id IS NULL because the streamed song was never inserted into
        // `tracks` -- are still returned. For those rows the local-track columns
        // are NULL, so fall back to the payload_* columns captured at enqueue
        // time (see M021SubsonicScrobble). (#291)
        var queueSQL = """
        SELECT q.id AS queue_id, q.played_at,
               COALESCE(t.title, q.payload_title) AS title,
               COALESCE(a.name, q.payload_artist) AS artist_name,
               COALESCE(al.title, q.payload_album) AS album_title
          FROM scrobble_queue q
          LEFT JOIN tracks t ON t.id = q.track_id
          LEFT JOIN artists a ON a.id = t.artist_id
          LEFT JOIN albums al ON al.id = t.album_id
        """
        var queueArgs: StatementArguments = []
        if let pid = providerID {
            queueSQL += """
             WHERE EXISTS (
               SELECT 1 FROM scrobble_submissions s
                WHERE s.queue_id = q.id AND s.provider_id = ?
             )
            """
            queueArgs = [pid]
        }
        queueSQL += " ORDER BY q.played_at DESC LIMIT ?"
        queueArgs += [limit]

        let queueRows = try Row.fetchAll(db, sql: queueSQL, arguments: queueArgs)
        guard !queueRows.isEmpty else { return [] }

        // Gather all matching queue IDs.
        let queueIDs: [Int64] = queueRows.map { $0["queue_id"] }

        // Fetch per-provider submission statuses in one query.
        let placeholders = queueIDs.map { _ in "?" }.joined(separator: ",")
        let subRows = try Row.fetchAll(
            db,
            sql: "SELECT queue_id, provider_id, status FROM scrobble_submissions WHERE queue_id IN (\(placeholders))",
            arguments: StatementArguments(queueIDs)
        )

        // Group statuses by queue_id.
        var statusMap: [Int64: [String: RecentRow.SubmissionStatus]] = [:]
        for sub in subRows {
            let qid: Int64 = sub["queue_id"]
            let pid: String = sub["provider_id"]
            let rawStatus: String = sub["status"] ?? "pending"
            statusMap[qid, default: [:]][pid] = RecentRow.SubmissionStatus(rawValue: rawStatus) ?? .pending
        }

        return queueRows.map { row in
            let qid: Int64 = row["queue_id"]
            return RecentRow(
                queueID: qid,
                playedAt: Date(timeIntervalSince1970: TimeInterval(row["played_at"] as Int)),
                title: row["title"] ?? "",
                artist: row["artist_name"] ?? "",
                album: row["album_title"],
                statusByProvider: statusMap[qid] ?? [:]
            )
        }
    }

    /// Stream live `Stats` for the UI.
    nonisolated func observeStats(now: @Sendable @escaping () -> Date = { Date() }) -> AsyncThrowingStream<Stats, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [database = self.db] in
                let upstream = await database.observe { db -> Stats in
                    let pending = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM scrobble_queue WHERE submitted = 0 AND dead = 0
                    """) ?? 0
                    let dead = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM scrobble_queue WHERE dead = 1
                    """) ?? 0
                    let startOfDay = Calendar(identifier: .gregorian).startOfDay(for: now())
                    let submittedToday = try Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(DISTINCT queue_id) FROM scrobble_submissions
                         WHERE status IN ('sent', 'sent_unconfirmed') AND submitted_at >= ?
                        """,
                        arguments: [Int(startOfDay.timeIntervalSince1970)]
                    ) ?? 0
                    return Stats(pending: pending, dead: dead, submittedToday: submittedToday)
                }
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
