import GRDB
import Testing
@testable import Persistence

@Suite("M012 Scrobbling Migration")
struct M012ScrobblingTests {
    @Test("scrobble_queue gains dead + last_error columns")
    func deadAndLastErrorColumnsAdded() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(scrobble_queue)")
                .compactMap { $0["name"] as String? }
        }
        #expect(columns.contains("dead"))
        #expect(columns.contains("last_error"))
    }

    @Test("uniq_scrobble_queue_track_playedat is enforced")
    func uniqueIndexEnforced() async throws {
        let db = try await Database(location: .inMemory)
        try await db.write { grdb in
            try grdb.execute(sql: "INSERT INTO artists (name) VALUES ('A')")
            try grdb.execute(sql: """
            INSERT INTO tracks (file_url, title, artist_id, duration, added_at, updated_at)
            VALUES ('/tmp/a.flac', 'A', 1, 100.0, 0, 0)
            """)
            try grdb.execute(sql: """
            INSERT INTO scrobble_queue (track_id, played_at, duration_played)
            VALUES (1, 1700000000, 100.0)
            """)
        }
        // Duplicate (track_id, played_at) → INSERT OR IGNORE is no-op; raw insert raises.
        await #expect(throws: (any Error).self) {
            try await db.write { grdb in
                try grdb.execute(sql: """
                INSERT INTO scrobble_queue (track_id, played_at, duration_played)
                VALUES (1, 1700000000, 100.0)
                """)
            }
        }
        let count = try await db.read { grdb in
            try Int.fetchOne(grdb, sql: "SELECT COUNT(*) FROM scrobble_queue") ?? 0
        }
        #expect(count == 1)
    }

    @Test("scrobble_submissions table exists with composite primary key")
    func submissionsTableShape() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(scrobble_submissions)")
                .compactMap { $0["name"] as String? }
        }
        for required in ["queue_id", "provider_id", "status", "submitted_at", "attempts", "next_attempt_at", "last_error"] {
            #expect(columns.contains(required), "missing column \(required)")
        }
    }

    @Test("submissions cascade-delete when queue row is removed")
    func cascadeDelete() async throws {
        let db = try await Database(location: .inMemory)
        try await db.write { grdb in
            try grdb.execute(sql: "INSERT INTO artists (name) VALUES ('A')")
            try grdb.execute(sql: """
            INSERT INTO tracks (file_url, title, artist_id, duration, added_at, updated_at)
            VALUES ('/tmp/a.flac', 'A', 1, 100.0, 0, 0)
            """)
            try grdb.execute(sql: """
            INSERT INTO scrobble_queue (track_id, played_at, duration_played)
            VALUES (1, 1700000000, 100.0)
            """)
            try grdb.execute(sql: """
            INSERT INTO scrobble_submissions (queue_id, provider_id, status)
            VALUES (1, 'lastfm', 'pending')
            """)
            try grdb.execute(sql: "DELETE FROM scrobble_queue WHERE id = 1")
        }
        let remaining = try await db.read { grdb in
            try Int.fetchOne(grdb, sql: "SELECT COUNT(*) FROM scrobble_submissions") ?? -1
        }
        #expect(remaining == 0)
    }
}
