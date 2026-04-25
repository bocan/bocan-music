import Acoustics
import Foundation
import Observability
import Persistence

// MARK: - FingerprintStore

/// Persists AcoustID fingerprint results to the `tracks` table.
///
/// Writing always happens regardless of whether the user ultimately applies
/// the candidate — the fingerprint is an intrinsic property of the audio.
public actor FingerprintStore {
    private let database: Database
    private let log = AppLogger.make(.library)

    public init(database: Database) {
        self.database = database
    }

    /// Saves the Chromaprint fingerprint string and AcoustID lookup ID for a track.
    ///
    /// Safe to call multiple times; subsequent calls overwrite the previous values.
    public func save(trackID: Int64, fingerprint: String, acoustidID: String?) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: """
                UPDATE tracks
                   SET acoustid_fingerprint = ?,
                       acoustid_id = ?
                 WHERE id = ?
                """,
                arguments: [fingerprint, acoustidID, trackID]
            )
        }
        self.log.debug("fingerprint.stored", ["trackID": trackID])
    }
}
