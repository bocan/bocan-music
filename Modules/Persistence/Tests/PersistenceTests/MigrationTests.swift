import Foundation
import GRDB
import Testing
@testable import Persistence

@Suite("Migration Tests")
struct MigrationTests {
    @Test("Migrations apply cleanly to an empty database")
    func migrationsApplyToEmptyDatabase() async throws {
        let db = try await Database(location: .inMemory)
        let version = try await db.schemaVersion()
        #expect(version == 23)
    }

    @Test("Integrity check passes after migration")
    func integrityCheckPassesAfterMigration() async throws {
        let db = try await Database(location: .inMemory)
        try await db.integrityCheck() // throws on failure
    }

    @Test("All expected tables exist after M001")
    func allTablesExistAfterMigration() async throws {
        let db = try await Database(location: .inMemory)
        let tables = try await db.read { grdb in
            try String.fetchAll(
                grdb,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
        }
        let expected = [
            "albums", "app_metadata", "artists", "cover_art",
            "grdb_migrations", "lyrics", "play_history",
            "playlist_tracks", "playlists", "podcast_episode_state",
            "podcast_episodes", "podcasts",
            "scrobble_queue", "settings", "tracks",
        ]
        for name in expected {
            #expect(tables.contains(name), "Expected table '\(name)' not found")
        }
    }

    @Test("FTS virtual tables exist after M001")
    func ftsTablesExistAfterMigration() async throws {
        let db = try await Database(location: .inMemory)
        let tables = try await db.read { grdb in
            try String.fetchAll(
                grdb,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%_fts' ORDER BY name"
            )
        }
        let expected = ["albums_fts", "artists_fts", "tracks_fts"]
        for name in expected {
            #expect(tables.contains(name), "Expected FTS table '\(name)' not found")
        }
    }

    @Test("app_metadata is seeded with schema_version = 1")
    func appMetadataSeeded() async throws {
        let db = try await Database(location: .inMemory)
        let value = try await db.read { grdb in
            try String.fetchOne(
                grdb,
                sql: "SELECT value FROM app_metadata WHERE key = 'schema_version'"
            )
        }
        #expect(value == "1")
    }

    @Test("Migrator reports twenty-three migrations")
    func migratorReportsAllMigrations() {
        let migrator = Migrator.make()
        #expect(migrator.migrations.count == 23)
    }

    @Test("M022 rolls up queue rows stranded by ignored submissions")
    func m022RepairsStrandedIgnoredRows() throws {
        let queue = try DatabaseQueue()
        var migrator = Migrator.make()
        try migrator.migrate(queue, upTo: "021_subsonic_scrobble")

        // Seed two pre-022 queue rows (Subsonic identity, so no tracks FK):
        // one stranded (only submission is ignored, never rolled up) and one
        // legitimately pending (live submission outstanding).
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO scrobble_queue
              (id, track_id, played_at, duration_played, submitted, submission_attempts, dead,
               subsonic_server_id, subsonic_song_id, payload_title, payload_artist, payload_duration)
            VALUES (1, NULL, 1000, 200, 0, 0, 0, 'srv', 'song-1', 'Stranded', 'Artist', 240),
                   (2, NULL, 2000, 200, 0, 0, 0, 'srv', 'song-2', 'Pending', 'Artist', 240)
            """)
            try db.execute(sql: """
            INSERT INTO scrobble_submissions (queue_id, provider_id, status, attempts)
            VALUES (1, 'subsonic', 'ignored', 1),
                   (2, 'subsonic', 'ignored', 1),
                   (2, 'lastfm', 'pending', 0)
            """)
        }

        try migrator.migrate(queue)

        let submittedFlags = try queue.read { db in
            try Int.fetchAll(db, sql: "SELECT submitted FROM scrobble_queue ORDER BY id")
        }
        #expect(submittedFlags == [1, 0], "ignored-only row must roll up; row with a live submission must stay pending")
    }

    @Test("Playlists table has kind and accent_color after M007")
    func playlistKindAccentColumns() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(playlists)")
                .compactMap { $0["name"] as String? }
        }
        #expect(columns.contains("kind"))
        #expect(columns.contains("accent_color"))
        #expect(columns.contains("smart_random_seed"))
    }

    @Test("Tracks table has CUE virtual-track columns after M013")
    func cueVirtualTrackColumns() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(tracks)")
                .compactMap { $0["name"] as String? }
        }
        #expect(columns.contains("start_offset_ms"))
        #expect(columns.contains("end_offset_ms"))
        #expect(columns.contains("source_file_url"))
    }

    @Test("Tracks table has extended_tags column after M015")
    func extendedTagsColumn() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(tracks)")
                .compactMap { $0["name"] as String? }
        }
        #expect(columns.contains("extended_tags"))
    }

    @Test("Tracks table has needs_conflict_review column after M018")
    func needsConflictReviewColumn() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(tracks)")
                .compactMap { $0["name"] as String? }
        }
        #expect(columns.contains("needs_conflict_review"))
    }

    @Test("WAL journal mode is active on an on-disk database (#288)")
    func walModeOnDisk() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bocan-wal-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let db = try await Database(location: .custom(url))
        let mode = try await db.read { grdb in
            try String.fetchOne(grdb, sql: "PRAGMA journal_mode")
        }
        #expect(mode == "wal", "Expected WAL journal mode; got '\(mode ?? "nil")' — pragma was silently swallowed")
    }
}
