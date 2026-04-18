import Foundation
import Testing
@testable import Persistence

@Suite("Concurrency Tests")
struct ConcurrencyTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makeTrack(index: Int) -> Track {
        let now = Int64(Date().timeIntervalSince1970)
        return Track(
            fileURL: "file:///tmp/concurrent-\(index).flac",
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "flac",
            duration: 180,
            title: "Track \(index)",
            addedAt: now,
            updatedAt: now
        )
    }

    @Test(
        "Concurrent readers and writers do not crash",
        .timeLimit(.minutes(1))
    )
    func concurrentReadersAndWriters() async throws {
        let db = try await makeDatabase()
        let repo = TrackRepository(database: db)

        // Seed 20 tracks
        for i in 0 ..< 20 {
            _ = try await repo.insert(self.makeTrack(index: i))
        }

        // Launch 8 readers and 2 writers concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            for r in 0 ..< 8 {
                group.addTask {
                    for _ in 0 ..< 50 {
                        let count = try await repo.count()
                        #expect(count >= 20, "Reader \(r) got unexpected count")
                    }
                }
            }
            for wr in 0 ..< 2 {
                group.addTask {
                    for j in 0 ..< 10 {
                        _ = try await repo.insert(self.makeTrack(index: 1000 + wr * 100 + j))
                    }
                }
            }
            try await group.waitForAll()
        }

        let final = try await repo.count()
        #expect(final >= 40) // 20 seed + 20 writes
    }

    @Test("500 rapid inserts succeed without deadlock")
    func rapidInsertsNoDeadlock() async throws {
        let db = try await makeDatabase()
        let repo = TrackRepository(database: db)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0 ..< 500 {
                group.addTask {
                    _ = try await repo.insert(self.makeTrack(index: 5000 + i))
                }
            }
            try await group.waitForAll()
        }
        let count = try await repo.count()
        #expect(count == 500)
    }
}
