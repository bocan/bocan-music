import GRDB

/// Migration 053: `sync_transcodes` (ADR-088, Sync & Transcode).
///
/// The transcode ledger: one row per (track, preset) recording which source
/// `content_hash` the artifact was derived from and the artifact's `sha256`,
/// `size`, and serve state. The row outlives the artifact bytes on disk by
/// design: the manifest and the Settings size estimate read the ledger, never
/// the filesystem, so `/v1/manifest` stays free of per-track file I/O. A row
/// is valid only while `source_content_hash` matches the track's current
/// `content_hash`; retagging invalidates it and the coordinator re-encodes.
///
/// `served_at` is stamped when a file response delivers the artifact through
/// EOF; the coordinator's sweep then releases the bytes (prepare-and-release,
/// the ADR's default) unless the keep toggle is on.
enum M053SyncTranscodes {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("053_sync_transcodes") { db in
            try db.execute(
                sql: """
                CREATE TABLE sync_transcodes (
                    track_id            INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                    preset              TEXT    NOT NULL,
                    source_content_hash TEXT    NOT NULL,
                    sha256              TEXT    NOT NULL,
                    size                INTEGER NOT NULL,
                    bitrate             INTEGER,
                    created_at          INTEGER NOT NULL,
                    served_at           INTEGER,
                    PRIMARY KEY (track_id, preset)
                )
                """
            )
        }
    }
}
