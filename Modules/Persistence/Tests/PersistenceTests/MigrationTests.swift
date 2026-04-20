import GRDB
import Testing
@testable import Persistence

@Suite("Migration Tests")
struct MigrationTests {
    @Test("Migrations apply cleanly to an empty database")
    func migrationsApplyToEmptyDatabase() async throws {
        let db = try await Database(location: .inMemory)
        let version = try await db.schemaVersion()
        #expect(version == 6)
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
            "playlist_tracks", "playlists", "scrobble_queue", "settings", "tracks",
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

    @Test("Migrator reports six migrations")
    func migratorReportsAllMigrations() {
        let migrator = Migrator.make()
        #expect(migrator.migrations.count == 6)
    }
}
