import Foundation
import GRDB

/// Access to the `sync_meta` singleton: the stable per-Mac `server_id` and the
/// monotonic `generation` counter the phone polls via `/v1/ping` (Phone Sync,
/// phase 22). The row is created lazily on first access.
public struct SyncMetaRepository: Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// The stable server id, minted and persisted on first read.
    public func serverId() async throws -> String {
        try await self.database.write { db in
            try Self.ensureRow(db)
            return try String.fetchOne(db, sql: "SELECT server_id FROM sync_meta WHERE id = 1") ?? ""
        }
    }

    /// The current generation counter (0 if never bumped).
    public func generation() async throws -> Int {
        try await self.database.read { db in
            try Int.fetchOne(db, sql: "SELECT generation FROM sync_meta WHERE id = 1") ?? 0
        }
    }

    /// Atomically increments the generation counter and returns the new value.
    @discardableResult
    public func bumpGeneration() async throws -> Int {
        try await self.database.write { db in
            try Self.ensureRow(db)
            try db.execute(sql: "UPDATE sync_meta SET generation = generation + 1 WHERE id = 1")
            return try Int.fetchOne(db, sql: "SELECT generation FROM sync_meta WHERE id = 1") ?? 0
        }
    }

    /// Emits once immediately and again whenever a sync-relevant table changes
    /// (tracks, playlists, membership, podcast episode state, or the sync
    /// profile). The SyncServer change observer debounces this and bumps the
    /// generation counter.
    public func observeLibraryChanges() async -> AsyncThrowingStream<Void, Error> {
        await self.database.observe(regions: [
            Table("tracks"),
            Table("playlists"),
            Table("playlist_tracks"),
            Table("podcast_episode_state"),
            // Show content and artwork_hash feed the manifest Podcast object
            // (22-10); a hash change must bump so the phone re-syncs art.
            Table("podcasts"),
            Table("sync_profile"),
        ]) { _ in }
    }

    /// Creates the singleton row with a fresh server id if it does not exist,
    /// preserving an existing id.
    private static func ensureRow(_ db: GRDB.Database) throws {
        try db.execute(
            sql: "INSERT INTO sync_meta (id, server_id, generation) VALUES (1, ?, 0) ON CONFLICT(id) DO NOTHING",
            arguments: [UUID().uuidString]
        )
    }
}
