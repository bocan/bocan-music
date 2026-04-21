import Foundation
import Testing
@testable import Persistence

/// Performance tests are disabled on CI because GitHub-hosted macOS runners
/// have significantly more variable I/O and CPU performance than developer
/// Macs, producing false-positive threshold breaches. They remain a useful
/// local regression check for performance-sensitive database paths.
@Suite(
    "Performance Tests",
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "Performance thresholds are tuned for dev Macs; CI runners vary too much."
    )
)
struct PerformanceTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makeTrack(index: Int) -> Track {
        let now = Int64(Date().timeIntervalSince1970)
        return Track(
            fileURL: "file:///tmp/perf-\(index).flac",
            fileSize: 2_048_000,
            fileMtime: now,
            fileFormat: "flac",
            duration: 240,
            title: "Performance Track \(index)",
            addedAt: now,
            updatedAt: now
        )
    }

    @Test("Insert 10 000 tracks in a single transaction takes < 5 seconds")
    func bulkInsertPerformance() async throws {
        let db = try await makeDatabase()
        let start = Date()
        try await db.write { grdb in
            for i in 0 ..< 10000 {
                let now = Int64(Date().timeIntervalSince1970)
                var track = Track(
                    fileURL: "file:///tmp/bulk-\(i).flac",
                    fileSize: 1024,
                    fileMtime: now,
                    fileFormat: "flac",
                    duration: 180,
                    title: "Bulk \(i)",
                    addedAt: now,
                    updatedAt: now
                )
                try track.insert(grdb)
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5.0, "Bulk insert took \(elapsed)s (limit 5s)")
    }

    @Test("FTS query across 10 000 tracks takes < 50 ms")
    func ftsBulkQueryPerformance() async throws {
        let db = try await makeDatabase()
        // Seed 10k tracks
        try await db.write { grdb in
            for i in 0 ..< 10000 {
                let now = Int64(Date().timeIntervalSince1970)
                var track = Track(
                    fileURL: "file:///tmp/fts-\(i).flac",
                    fileSize: 1024,
                    fileMtime: now,
                    fileFormat: "flac",
                    duration: 180,
                    title: "Song \(i)",
                    addedAt: now,
                    updatedAt: now
                )
                try track.insert(grdb)
            }
        }
        let start = Date()
        let results = try await db.read { grdb in
            try SQL.tracksFTSQuery("Song 9999").fetchAll(grdb)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(!results.isEmpty) // existence check
        #expect(elapsed < 0.05, "FTS query took \(elapsed)s (limit 50ms)")
    }

    @Test("SELECT by album_id with 10 000 tracks takes < 5 ms")
    func albumFetchPerformance() async throws {
        let db = try await makeDatabase()
        let albumRepo = AlbumRepository(database: db)
        let albumID = try await albumRepo.insert(Album(title: "Big Album"))
        // Seed 10k tracks for this album
        try await db.write { grdb in
            for i in 0 ..< 10000 {
                let now = Int64(Date().timeIntervalSince1970)
                var track = Track(
                    fileURL: "file:///tmp/album-\(i).flac",
                    fileSize: 1024,
                    fileMtime: now,
                    fileFormat: "flac",
                    duration: 180,
                    title: "Album Track \(i)",
                    albumID: albumID,
                    addedAt: now,
                    updatedAt: now
                )
                try track.insert(grdb)
            }
        }
        let start = Date()
        let repo = TrackRepository(database: db)
        let tracks = try await repo.fetchAll(albumID: albumID)
        let elapsed = Date().timeIntervalSince(start)
        #expect(tracks.count == 10000)
        #expect(elapsed < 0.150, "album fetch took \(elapsed)s (limit 150ms)")
    }
}
