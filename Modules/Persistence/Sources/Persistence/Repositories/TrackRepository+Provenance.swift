import Foundation
import GRDB

/// The transcode-detection queries (ADR-075 slice 2), split from the core CRUD so
/// each file stays focused.
public extension TrackRepository {
    /// Tracks still needing transcode analysis, oldest id first. `afterID` is
    /// a cursor so the batch job can page past files it failed to decode;
    /// `limit` bounds one batch. See ``provenanceCandidates`` for eligibility.
    func fetchNeedingProvenance(limit: Int, afterID: Int64 = 0) async throws -> [Track] {
        try await self.database.read { db in
            try Self.provenanceCandidates
                .filter(Column("id") > afterID)
                .order(Column("id"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Number of tracks `fetchNeedingProvenance` would still return, for
    /// batch-job progress reporting.
    func countNeedingProvenance() async throws -> Int {
        try await self.database.read { db in
            try Self.provenanceCandidates.fetchCount(db)
        }
    }

    /// Stores one transcode-detection verdict (ADR-075 slice 2).
    ///
    /// `analysedAt` is Unix epoch seconds; pass the shelf frequency only when
    /// `suspected` so the columns mirror `ProvenanceVerdict` exactly.
    func setProvenance(
        trackID: Int64,
        suspected: Bool,
        confidence: Double,
        shelfHz: Int?,
        analysedAt: Int64
    ) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: """
                UPDATE tracks
                SET provenance_suspected = ?,
                    provenance_confidence = ?,
                    provenance_shelf_hz = ?,
                    provenance_analysed_at = ?
                WHERE id = ?
                """,
                arguments: [suspected, confidence, shelfHz, analysedAt, trackID]
            )
        }
        self.log.debug("track.provenance", ["id": trackID, "suspected": suspected])
    }
}

private extension TrackRepository {
    /// Tracks eligible for provenance analysis: enabled, claiming lossless
    /// (lossy-from-lossy is out of scope for ADR-075), whole-file (CUE clips
    /// share one rip), with a bookmark to read through, and either never
    /// analysed or modified on disk since their verdict was written.
    static var provenanceCandidates: QueryInterfaceRequest<Track> {
        Track
            .filter(Column("disabled") == false)
            .filter(Column("is_lossless") == true)
            .filter(Column("file_bookmark") != nil)
            .filter(Column("provenance_analysed_at") == nil || Column("provenance_analysed_at") < Column("file_mtime"))
    }
}
