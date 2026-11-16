import Foundation
import GRDB
import Testing
@testable import Persistence

// MARK: - M056JellyfinScrobbleTests

/// ADR-097 slice 6: the Jellyfin identity on `scrobble_queue`.
@Suite("M056 Jellyfin scrobble columns")
struct M056JellyfinScrobbleTests {
    @Test("scrobble_queue has the two Jellyfin columns")
    func columnsExist() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in
            try Row.fetchAll(grdb, sql: "PRAGMA table_info(scrobble_queue)").compactMap { $0["name"] as String? }
        }
        #expect(columns.contains("jellyfin_server_id"))
        #expect(columns.contains("jellyfin_item_id"))
    }

    @Test("a Jellyfin row round-trips real values, and the same play twice is one row")
    func uniqueOnServerItemAndTime() async throws {
        let db = try await Database(location: .inMemory)
        let insert = """
        INSERT OR IGNORE INTO scrobble_queue
          (track_id, played_at, duration_played, submitted, submission_attempts, dead,
           jellyfin_server_id, jellyfin_item_id, payload_title, payload_artist, payload_duration)
        VALUES (NULL, ?, 180, 0, 0, 0, ?, ?, 'Song', 'Artist', 200)
        """
        try await db.write { grdb in
            try grdb.execute(sql: insert, arguments: [1000, "SERVER-A", "4f2a9c0d"])
            try grdb.execute(sql: insert, arguments: [1000, "SERVER-A", "4f2a9c0d"])
            try grdb.execute(sql: insert, arguments: [1001, "SERVER-A", "4f2a9c0d"])
        }
        let pairs = try await db.read { grdb in
            let rows = try Row.fetchAll(grdb, sql: """
            SELECT jellyfin_server_id, jellyfin_item_id FROM scrobble_queue ORDER BY played_at
            """)
            return rows.map { "\($0["jellyfin_server_id"] as String? ?? "-")/\($0["jellyfin_item_id"] as String? ?? "-")" }
        }
        #expect(pairs == ["SERVER-A/4f2a9c0d", "SERVER-A/4f2a9c0d"], "the second insert of the same play is ignored")
    }

    @Test("rows with no Jellyfin identity never collide on the Jellyfin index")
    func nullsDoNotCollide() async throws {
        let db = try await Database(location: .inMemory)
        try await db.write { grdb in
            for _ in 0 ..< 2 {
                try grdb.execute(sql: """
                INSERT INTO scrobble_queue
                  (track_id, played_at, duration_played, submitted, submission_attempts, dead,
                   subsonic_server_id, subsonic_song_id, payload_title, payload_artist)
                VALUES (NULL, 1000, 100, 0, 0, 0, 'S', ?, 'T', 'A')
                """, arguments: [UUID().uuidString])
            }
        }
        let count = try await db.read { grdb in
            try Int.fetchOne(grdb, sql: "SELECT COUNT(*) FROM scrobble_queue") ?? 0
        }
        #expect(count == 2)
    }
}
