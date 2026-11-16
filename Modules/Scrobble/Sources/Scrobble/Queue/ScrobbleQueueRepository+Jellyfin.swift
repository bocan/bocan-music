import Foundation
import GRDB
import Playback

// MARK: - Jellyfin enqueue

/// The Jellyfin twin of the Subsonic enqueue (ADR-097 slice 6).
public extension ScrobbleQueueRepository {
    /// Enqueues a Jellyfin play (ADR-097), the twin of `enqueueSubsonic`. The
    /// song has no `tracks` row, so its identity (`server`, `item`) and its
    /// metadata go on the queue row. Idempotent on
    /// `(jellyfin_server_id, jellyfin_item_id, played_at)` (M056).
    ///
    /// `payload_duration` is the song's length. When the server sent none, it
    /// is the time played instead, which `ScrobbleService.isEligible` already
    /// treats as the length; the Jellyfin provider reports it as the stop
    /// position (ADR-097, "Play reports and favourites").
    @discardableResult
    func enqueueJellyfin(
        context: JellyfinPlayContext,
        playedAt: Date,
        durationPlayed: TimeInterval,
        providerIDs: [String]
    ) async throws -> Int64? {
        let playedAtEpoch = Int(playedAt.timeIntervalSince1970)
        let serverIDString = context.serverID.uuidString
        let itemID = context.itemID
        let title = context.title
        let artist = context.artist
        let album = context.album
        let albumArtist = context.albumArtist
        let duration = context.duration > 0 ? context.duration : durationPlayed
        return try await self.db.write { db in
            // track_id stays NULL: there is no local row to point at.
            try db.execute(sql: """
            INSERT OR IGNORE INTO scrobble_queue
              (track_id, played_at, duration_played, submitted, submission_attempts, dead,
               jellyfin_server_id, jellyfin_item_id,
               payload_title, payload_artist, payload_album, payload_album_artist, payload_duration)
            VALUES (NULL, ?, ?, 0, 0, 0, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                playedAtEpoch, durationPlayed,
                serverIDString, itemID,
                title, artist, album, albumArtist, duration,
            ])
            let queueID: Int64? = try Int64.fetchOne(
                db,
                sql: """
                SELECT id FROM scrobble_queue
                 WHERE jellyfin_server_id = ? AND jellyfin_item_id = ? AND played_at = ?
                """,
                arguments: [serverIDString, itemID, playedAtEpoch]
            )
            guard let queueID else { return nil }
            try Self.insertPendingSubmissions(db, queueID: queueID, providerIDs: providerIDs)
            return queueID
        }
    }
}
