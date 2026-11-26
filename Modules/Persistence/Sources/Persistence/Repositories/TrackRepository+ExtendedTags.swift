import Foundation
import GRDB

/// The single-column tag map write, split from the core CRUD so the file
/// stays inside the lint length limit.
public extension TrackRepository {
    /// Writes `json` to `tracks.extended_tags` and no other column. The quick
    /// scan's one-time backfill (#735) uses it for an unchanged file whose
    /// row never stored its tag map: a full-row `update` would risk putting
    /// back a play count or edit written while the scan ran.
    func setExtendedTags(trackID: Int64, json: String) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE tracks SET extended_tags = ? WHERE id = ?",
                arguments: [json, trackID]
            )
        }
        self.log.debug("track.extendedTags", ["id": trackID])
    }
}
