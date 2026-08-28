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
        #expect(version == 45)
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
            "podcast_episode_transcript", "podcast_episodes", "podcasts",
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

    @Test("Migrator reports thirty-eight migrations")
    func migratorReportsAllMigrations() {
        let migrator = Migrator.make()
        #expect(migrator.migrations.count == 45)
    }

    @Test("radio_stations has the stream-detail profile columns after M037")
    func radioStationStreamDetailColumns() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(radio_stations)")
                .compactMap { $0["name"] as String? }
        }
        for name in ["last_container", "last_sample_rate_hz", "last_channels"] {
            #expect(columns.contains(name), "Expected column '\(name)' not found")
        }
    }

    @Test("radio_stations exists with its catalog and profile columns after M036")
    func radioStationsTable() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(radio_stations)")
                .compactMap { $0["name"] as String? }
        }
        for name in [
            "name", "stream_url", "home_page_url", "genre", "station_description",
            "last_codec", "last_bitrate_kbps", "last_connected_at", "added_at",
        ] {
            #expect(columns.contains(name), "Expected column '\(name)' not found")
        }

        // stream_url is the catalog's identity key; duplicates must be rejected.
        try await db.write { grdb in
            try grdb.execute(
                sql: "INSERT INTO radio_stations (name, stream_url, added_at) VALUES ('A', 'https://x', 0)"
            )
        }
        await #expect(throws: (any Error).self) {
            try await db.write { grdb in
                try grdb.execute(
                    sql: "INSERT INTO radio_stations (name, stream_url, added_at) VALUES ('B', 'https://x', 0)"
                )
            }
        }
    }

    @Test("imported_listens exists with its identity index after M035")
    func importedListensTable() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(imported_listens)")
                .compactMap { $0["name"] as String? }
        }
        for name in ["source", "played_at", "artist", "title", "album", "track_mbid", "track_id"] {
            #expect(columns.contains(name), "Expected column '\(name)' not found")
        }
        let indexes = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA index_list(imported_listens)")
                .compactMap { $0["name"] as String? }
        }
        #expect(indexes.contains("idx_imported_listens_identity"), "re-imports rely on the unique identity index")
    }

    @Test("Tracks table has the provenance columns after M034")
    func provenanceColumns() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(tracks)")
                .compactMap { $0["name"] as String? }
        }
        for name in [
            "provenance_suspected",
            "provenance_confidence",
            "provenance_shelf_hz",
            "provenance_analysed_at",
        ] {
            #expect(columns.contains(name), "Expected column '\(name)' not found")
        }
    }

    @Test("podcast_episode_state has content_hash after M032")
    func podcastEpisodeContentHashColumn() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(podcast_episode_state)")
                .compactMap { $0["name"] as String? }
        }
        #expect(columns.contains("content_hash"))
    }

    @Test("podcasts table has artwork_hash after M033")
    func podcastArtworkHashColumn() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(podcasts)")
                .compactMap { $0["name"] as String? }
        }
        #expect(columns.contains("artwork_hash"))
    }

    @Test("Phone Sync tables exist with the expected columns after M031")
    func phoneSyncTablesExist() async throws {
        let db = try await Database(location: .inMemory)
        let tables = try await db.read { grdb in
            try String.fetchAll(
                grdb,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
        }
        for name in ["trusted_devices", "sync_meta", "sync_profile"] {
            #expect(tables.contains(name), "Expected table '\(name)' not found")
        }

        let trustedColumns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(trusted_devices)")
                .compactMap { $0["name"] as String? }
        }
        for name in ["fingerprint", "cert_der", "device_name", "paired_at"] {
            #expect(trustedColumns.contains(name), "Expected column '\(name)' not found")
        }
    }

    @Test("sync_meta and sync_profile enforce their singleton CHECK (id = 1)")
    func singletonRowsAreEnforced() async throws {
        let db = try await Database(location: .inMemory)
        await #expect(throws: (any Error).self) {
            try await db.write { grdb in
                try grdb.execute(
                    sql: "INSERT INTO sync_meta (id, server_id, generation) VALUES (2, 'x', 0)"
                )
            }
        }
        await #expect(throws: (any Error).self) {
            try await db.write { grdb in
                try grdb.execute(
                    sql: "INSERT INTO sync_profile (id, profile_json) VALUES (2, x'00')"
                )
            }
        }
    }

    @Test("M030 clears HTTP validators so the next refresh re-parses every feed")
    func m030ForcesReparse() throws {
        let queue = try DatabaseQueue()
        var migrator = Migrator.make()
        try migrator.migrate(queue, upTo: "029_podcast_podroll")

        // Seed a subscription that already carries HTTP validators (the state that
        // makes a stable feed answer 304 and skip the parse forever).
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO podcasts (feed_url, title, http_etag, http_last_modified, subscribed, added_at)
            VALUES ('https://example.com/feed.xml', 'Example', '"abc123"', 'Mon, 01 Jan 2026 00:00:00 GMT', 1, 0)
            """)
        }

        try migrator.migrate(queue)

        let (etag, lastModified) = try queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT http_etag, http_last_modified FROM podcasts")
            return (row?["http_etag"] as String?, row?["http_last_modified"] as String?)
        }
        #expect(etag == nil, "M030 must clear http_etag so the next GET is unconditional")
        #expect(lastModified == nil, "M030 must clear http_last_modified so the next GET is unconditional")
    }

    @Test("podcasts table has podroll_json after M029")
    func podcastPodrollColumn() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(podcasts)")
                .compactMap { $0["name"] as String? }
        }
        #expect(columns.contains("podroll_json"))
    }

    @Test("podcasts table has funding_text after M025")
    func podcastFundingTextColumn() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(podcasts)")
                .compactMap { $0["name"] as String? }
        }
        #expect(columns.contains("funding_text"))
    }

    @Test("podcast_episode_transcript table has the expected columns after M026")
    func podcastTranscriptTable() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(podcast_episode_transcript)")
                .compactMap { $0["name"] as String? }
        }
        for name in ["podcast_id", "guid", "content", "format", "language", "source_url", "fetched_at"] {
            #expect(columns.contains(name), "Expected column '\(name)' not found")
        }
    }

    @Test("podcasts table has the per-show settings columns after M027")
    func podcastPerShowSettingsColumns() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(podcasts)")
                .compactMap { $0["name"] as String? }
        }
        for name in ["playback_speed", "episode_sort", "retention_limit", "show_type"] {
            #expect(columns.contains(name), "Expected column '\(name)' not found")
        }
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

    @Test("M045 creates pending_maintenance and requests one full rescan for itself (#425)")
    func pendingMaintenanceSelfRequest() async throws {
        let db = try await Database(location: .inMemory)
        let requests = try await PendingMaintenanceRepository(database: db).requests(task: PendingMaintenance.Task.fullRescan)
        #expect(requests.map(\.requestedBy) == ["045_pending_maintenance"])
    }

    @Test("M044 drops the CUE virtual-track columns M013 added (#406)")
    func cueVirtualTrackColumnsDropped() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(tracks)")
                .compactMap { $0["name"] as String? }
        }
        #expect(!columns.contains("start_offset_ms"))
        #expect(!columns.contains("end_offset_ms"))
        #expect(!columns.contains("source_file_url"))
        let indexes = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA index_list(tracks)").compactMap { $0["name"] as String? }
        }
        #expect(!indexes.contains("idx_tracks_source_file_url"))
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

    @Test("M038 purges virtual rows WITH their dependents on a populated v37 database")
    func trackMarkersMigrationPurgesDependents() async throws {
        // GRDB runs migrations with foreign keys disabled and validates with
        // a full foreign_key_check afterwards — ON DELETE CASCADE never
        // fires inside a migration. The first M038 relied on it and bricked
        // a real library whose virtual tracks had scrobble history (the
        // post-check refused the orphaned scrobble_queue row and the
        // database would not open). Reproduce that world: migrate to v37,
        // plant a virtual track with a scrobble, its submission, a playlist
        // membership, and play history, then complete the migration.
        var migrator = Migrator.make()
        let dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue, upTo: "037_radio_station_stream_details")
        try await dbQueue.write { grdb in
            try grdb.execute(sql: """
            INSERT INTO tracks (id, file_url, file_size, file_mtime, file_format, duration, added_at, updated_at)
            VALUES (7, 'file:///m/a.flac?cue=1', 1, 1, 'flac', 10, 1, 1)
            """)
            try grdb.execute(sql: """
            INSERT INTO scrobble_queue (id, track_id, played_at, duration_played) VALUES (9, 7, 1, 10)
            """)
            try grdb.execute(sql: """
            INSERT INTO scrobble_submissions (queue_id, provider_id, status) VALUES (9, 'lastfm', 'sent')
            """)
            try grdb.execute(sql: "INSERT INTO playlists (id, name, created_at, updated_at) VALUES (3, 'P', 1, 1)")
            try grdb.execute(sql: """
            INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (3, 7, 0)
            """)
            try grdb.execute(sql: """
            INSERT INTO play_history (track_id, played_at, duration_played) VALUES (7, 1, 10)
            """)
        }

        try migrator.migrate(dbQueue)

        try await dbQueue.read { grdb in
            let virtual = try Int.fetchOne(grdb, sql: "SELECT COUNT(*) FROM tracks WHERE file_url LIKE '%?cue=%'")
            assert(virtual == 0)
            let violations = try Row.fetchAll(grdb, sql: "PRAGMA foreign_key_check")
            assert(violations.isEmpty)
            let tables = try String.fetchAll(grdb, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            assert(tables.contains("track_markers"))
        }
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
