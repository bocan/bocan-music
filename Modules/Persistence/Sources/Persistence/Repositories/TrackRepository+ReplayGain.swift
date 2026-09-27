import Foundation
import GRDB

/// The ReplayGain batch writes, split from the core CRUD so each file stays
/// inside the lint length limit. They set only the ReplayGain columns: a
/// full-row `update` from a row read when a long batch started would put back
/// a stale play count, rating or edit written since.
public extension TrackRepository {
    /// Writes `track`'s `replaygain_track_gain` and `replaygain_track_peak`,
    /// and no other column. The batch analysis measures a track minutes after
    /// it read the row; a play, rating or edit since then is kept. A track
    /// without an id is skipped.
    func setTrackReplayGain(from track: Track) async throws {
        guard let id = track.id else { return }
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE tracks SET replaygain_track_gain = ?, replaygain_track_peak = ? WHERE id = ?",
                arguments: [track.replaygainTrackGain, track.replaygainTrackPeak, id]
            )
        }
        self.log.debug("track.trackReplayGain", ["id": id])
    }

    /// Writes each track's `replaygain_album_gain` and `replaygain_album_peak`,
    /// and no other column, in one transaction (#579). A whole library of
    /// albums is thousands of rows. Tracks without an id are skipped. All or
    /// nothing: a failure rolls back every row.
    func setAlbumReplayGain(from tracks: [Track]) async throws {
        let rows = tracks.filter { $0.id != nil }
        guard !rows.isEmpty else { return }
        try await self.database.write { db in
            let statement = try db.makeStatement(sql: """
            UPDATE tracks SET replaygain_album_gain = ?, replaygain_album_peak = ? WHERE id = ?
            """)
            for track in rows {
                try statement.execute(arguments: [track.replaygainAlbumGain, track.replaygainAlbumPeak, track.id])
            }
        }
        self.log.debug("track.albumReplayGain", ["count": rows.count])
    }
}
