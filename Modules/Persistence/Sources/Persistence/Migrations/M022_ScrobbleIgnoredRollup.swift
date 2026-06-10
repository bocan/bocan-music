import GRDB

/// Scrobble queue repair: roll up rows stranded by `markIgnored`.
///
/// Marking a submission `ignored` used to skip the "all submissions terminal,
/// so mark the queue row submitted" rollup that `markSucceeded` and
/// `markSentUnconfirmed` perform. A queue row whose last live submission ended
/// `ignored` therefore stranded at `submitted = 0`, `dead = 0`: counted as
/// pending by the stats badge forever, but never claimable by any worker and
/// never revived (reviveDead only touches `failed`). Mark those rows
/// submitted. Rows with no submissions at all are left alone; they cannot be
/// produced by `ScrobbleService` (it skips enqueueing when no provider is
/// connected) and silently resolving them would hide a different bug.
enum M022ScrobbleIgnoredRollup {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("022_scrobble_ignored_rollup") { db in
            try db.execute(sql: """
            UPDATE scrobble_queue
               SET submitted = 1
             WHERE submitted = 0
               AND dead = 0
               AND EXISTS (
                   SELECT 1 FROM scrobble_submissions s
                    WHERE s.queue_id = scrobble_queue.id
                   )
               AND NOT EXISTS (
                   SELECT 1 FROM scrobble_submissions s
                    WHERE s.queue_id = scrobble_queue.id
                      AND s.status NOT IN ('sent', 'sent_unconfirmed', 'ignored')
                   )
            """)
        }
    }
}
