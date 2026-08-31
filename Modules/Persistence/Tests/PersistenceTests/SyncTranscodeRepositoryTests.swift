import Foundation
import Testing
@testable import Persistence

/// The transcode ledger (ADR-088): rows record the artifact derived from a
/// source hash and stay authoritative after the bytes are released.
@Suite("Sync Transcode Repository Tests")
struct SyncTranscodeRepositoryTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    /// Inserts a track with a content hash and returns its id.
    private func insertTrack(
        db: Database,
        contentHash: String
    ) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            fileURL: "file:///tmp/\(UUID().uuidString).flac",
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "flac",
            duration: 200,
            title: "Song \(contentHash.prefix(6))",
            addedAt: now,
            updatedAt: now
        )
        track.contentHash = contentHash
        let repo = TrackRepository(database: db)
        return try await repo.insert(track)
    }

    private func makeRow(
        trackID: Int64,
        preset: String = "opus_128",
        sourceContentHash: String = "src-hash",
        sha256: String = "artifact-hash",
        size: Int64 = 4_200_000
    ) -> SyncTranscode {
        SyncTranscode(
            trackID: trackID,
            preset: preset,
            sourceContentHash: sourceContentHash,
            sha256: sha256,
            size: size,
            createdAt: Int64(Date().timeIntervalSince1970),
            bitrate: 128
        )
    }

    @Test("upsert round-trips real values into every column")
    func upsertRoundTrips() async throws {
        let db = try await makeDatabase()
        let trackID = try await insertTrack(db: db, contentHash: "src-hash")
        let repo = SyncTranscodeRepository(database: db)
        try await repo.upsert(self.makeRow(trackID: trackID))
        try await repo.stampServed(trackID: trackID, preset: "opus_128", at: 1_756_000_000)

        let row = try #require(
            try await repo.validRow(trackID: trackID, preset: "opus_128", sourceContentHash: "src-hash")
        )
        // The schema-discipline check: real, non-default values in every column.
        #expect(row.trackID == trackID)
        #expect(row.preset == "opus_128")
        #expect(row.sourceContentHash == "src-hash")
        #expect(row.sha256 == "artifact-hash")
        #expect(row.size == 4_200_000)
        #expect(row.bitrate == 128)
        #expect(row.createdAt > 0)
        #expect(row.servedAt == 1_756_000_000)
    }

    @Test("upsert replaces the row for the same track and preset")
    func upsertReplaces() async throws {
        let db = try await makeDatabase()
        let trackID = try await insertTrack(db: db, contentHash: "src-hash-2")
        let repo = SyncTranscodeRepository(database: db)
        try await repo.upsert(self.makeRow(trackID: trackID, sourceContentHash: "src-hash-2", sha256: "old"))
        try await repo.upsert(self.makeRow(trackID: trackID, sourceContentHash: "src-hash-2", sha256: "new"))
        let row = try #require(
            try await repo.validRow(trackID: trackID, preset: "opus_128", sourceContentHash: "src-hash-2")
        )
        #expect(row.sha256 == "new")
        #expect(try await repo.allValid(preset: "opus_128").count == 1)
    }

    @Test("validRow refuses a stale source hash")
    func validRowRefusesStale() async throws {
        let db = try await makeDatabase()
        let trackID = try await insertTrack(db: db, contentHash: "current")
        let repo = SyncTranscodeRepository(database: db)
        try await repo.upsert(self.makeRow(trackID: trackID, sourceContentHash: "outdated"))
        #expect(try await repo.validRow(trackID: trackID, preset: "opus_128", sourceContentHash: "current") == nil)
    }

    @Test("allValid returns only rows whose source hash still matches the track")
    func allValidFiltersStale() async throws {
        let db = try await makeDatabase()
        let freshID = try await insertTrack(db: db, contentHash: "fresh")
        let staleID = try await insertTrack(db: db, contentHash: "retagged")
        let repo = SyncTranscodeRepository(database: db)
        try await repo.upsert(self.makeRow(trackID: freshID, sourceContentHash: "fresh"))
        try await repo.upsert(self.makeRow(trackID: staleID, sourceContentHash: "old-hash"))
        let valid = try await repo.allValid(preset: "opus_128")
        #expect(valid.map(\.trackID) == [freshID])
    }

    @Test("deleteStale removes and returns retagged rows, keeping fresh ones")
    func deleteStaleRemovesRetagged() async throws {
        let db = try await makeDatabase()
        let freshID = try await insertTrack(db: db, contentHash: "fresh")
        let staleID = try await insertTrack(db: db, contentHash: "retagged")
        let repo = SyncTranscodeRepository(database: db)
        try await repo.upsert(self.makeRow(trackID: freshID, sourceContentHash: "fresh"))
        try await repo.upsert(self.makeRow(trackID: staleID, sourceContentHash: "old-hash"))

        let removed = try await repo.deleteStale(preset: "opus_128")
        #expect(removed.map(\.trackID) == [staleID])
        #expect(try await repo.allValid(preset: "opus_128").map(\.trackID) == [freshID])
        // Idempotent: nothing left to remove.
        #expect(try await repo.deleteStale(preset: "opus_128").isEmpty)
    }

    @Test("deleteAll clears one preset and leaves the other rung alone")
    func deleteAllScopedToPreset() async throws {
        let db = try await makeDatabase()
        let trackID = try await insertTrack(db: db, contentHash: "src")
        let repo = SyncTranscodeRepository(database: db)
        try await repo.upsert(self.makeRow(trackID: trackID, preset: "opus_128", sourceContentHash: "src"))
        try await repo.upsert(self.makeRow(trackID: trackID, preset: "mp3_320", sourceContentHash: "src"))

        let removed = try await repo.deleteAll(preset: "opus_128")
        #expect(removed == 1)
        #expect(try await repo.allValid(preset: "opus_128").isEmpty)
        #expect(try await repo.allValid(preset: "mp3_320").count == 1)
    }

    @Test("deleting the track cascades its ledger rows away")
    func trackDeleteCascades() async throws {
        let db = try await makeDatabase()
        let trackID = try await insertTrack(db: db, contentHash: "src")
        let repo = SyncTranscodeRepository(database: db)
        try await repo.upsert(self.makeRow(trackID: trackID, sourceContentHash: "src"))

        try await db.write { grdb in
            try grdb.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [trackID])
        }
        let remaining = try await db.read { grdb in
            try Int.fetchOne(grdb, sql: "SELECT COUNT(*) FROM sync_transcodes") ?? -1
        }
        #expect(remaining == 0)
    }
}
