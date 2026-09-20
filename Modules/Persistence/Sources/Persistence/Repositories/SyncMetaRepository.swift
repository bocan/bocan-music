import Foundation
import GRDB

/// Access to the `sync_meta` singleton: the stable per-Mac `server_id` and the
/// monotonic `generation` counter the phone polls via `/v1/ping` (Phone Sync,
/// ADR-060). The row is created lazily on first access.
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

    /// The `tracks` columns the manifest actually carries. Observing these
    /// instead of the whole table keeps the end-of-play write (`play_count`,
    /// `last_played_at`, `play_duration_total`) from bumping the generation and
    /// making the phone re-poll a manifest that did not change (#550).
    ///
    /// `content_hash` is in the list on purpose: a hash appearing is what makes
    /// a track eligible for the manifest, so the phone does need to hear it.
    private static let manifestTrackColumns = [
        "id", "file_url", "file_size", "file_format", "duration",
        "sample_rate", "bit_depth", "bitrate", "channel_count", "is_lossless",
        "title", "artist_id", "album_artist_id", "album_id",
        "track_number", "track_total", "disc_number", "disc_total",
        "year", "genre", "composer", "bpm", "rating", "loved",
        "replaygain_track_gain", "replaygain_track_peak",
        "replaygain_album_gain", "replaygain_album_peak",
        "content_hash", "disabled", "cover_art_hash",
    ].map { Column($0) }

    /// The `tracks` columns `TranscodeCoordinator.needsTranscode` and its
    /// target-set filters read.
    private static let transcodeTrackColumns = [
        "id", "disabled", "content_hash", "is_lossless", "bitrate",
    ].map { Column($0) }

    /// Emits once immediately and again whenever a sync-relevant table changes
    /// (tracks, playlists, membership, podcast episode state, or the sync
    /// profile). The SyncServer change observer debounces this and bumps the
    /// generation counter.
    ///
    /// - Parameter narrowTracksToManifestColumns: when `true`, only the
    ///   `tracks` columns the manifest carries are observed. The caller must
    ///   pass `false` whenever library membership can depend on a column
    ///   outside that set, which is the case for a profile that selects a
    ///   smart playlist (its criteria can key on `play_count`).
    public func observeLibraryChanges(
        narrowTracksToManifestColumns: Bool = false
    ) async -> AsyncThrowingStream<Void, Error> {
        let tracks: any DatabaseRegionConvertible = narrowTracksToManifestColumns
            ? Table("tracks").select(Self.manifestTrackColumns)
            : Table("tracks")
        return await self.database.observe(regions: [
            tracks,
            Table("playlists"),
            Table("playlist_tracks"),
            // The manifest carries each episode's play position and state, so
            // the periodic position write is a real change, not noise.
            Table("podcast_episode_state"),
            // Show content and artwork_hash feed the manifest Podcast object
            // (22-10); a hash change must bump so the phone re-syncs art.
            Table("podcasts"),
            Table("sync_profile"),
            // Transcode-ledger writes gate manifest inclusion under a
            // transcode preset (ADR-088), so the phone must re-poll.
            Table("sync_transcodes"),
        ]) { _ in }
    }

    /// Emits once immediately and again whenever the input to a transcode pass
    /// changes: the profile, playlist membership, or one of the `tracks`
    /// columns the pass's predicate reads.
    ///
    /// Deliberately narrower than ``observeLibraryChanges(narrowTracksToManifestColumns:)``
    /// in two ways (#550). It omits `sync_transcodes`, which the pass writes
    /// itself, so a pass no longer re-arms itself through its own ledger. And
    /// it observes only the predicate's `tracks` columns, so an end-of-play
    /// write no longer starts a whole-library pass. A membership change that
    /// only a smart playlist's criteria could see is therefore missed here;
    /// transcoding is prepare-ahead work with an on-demand fallback
    /// (`requestUrgent`, the 503-busy path of ADR-088), so the cost of missing
    /// one is a single encode at request time, not a stale library.
    public func observeTranscodeInputs() async -> AsyncThrowingStream<Void, Error> {
        await self.database.observe(regions: [
            Table("tracks").select(Self.transcodeTrackColumns),
            Table("playlists"),
            Table("playlist_tracks"),
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
