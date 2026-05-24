import Foundation
import Testing
@testable import Persistence

@Suite("ScrobbleRepository (legacy queue table)")
struct ScrobbleRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func seedTrack(_ db: Database) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        return try await TrackRepository(database: db).insert(
            Track(
                fileURL: "file:///tmp/\(UUID().uuidString).flac",
                fileSize: 1024,
                fileMtime: now,
                fileFormat: "flac",
                duration: 180,
                title: "T",
                addedAt: now,
                updatedAt: now
            )
        )
    }

    @Test("enqueue then fetchPending returns the row")
    func enqueueAndFetch() async throws {
        let db = try await makeDB()
        let trackID = try await seedTrack(db)
        let repo = ScrobbleRepository(database: db)
        let id = try await repo.enqueue(ScrobbleQueueItem(trackID: trackID, playedAt: 1_700_000_000, durationPlayed: 180))
        #expect(id > 0)
        let pending = try await repo.fetchPending()
        #expect(pending.count == 1)
        #expect(try await repo.pendingCount() == 1)
    }

    @Test("markSubmitted removes row from pending")
    func markSubmittedHides() async throws {
        let db = try await makeDB()
        let trackID = try await seedTrack(db)
        let repo = ScrobbleRepository(database: db)
        let id = try await repo.enqueue(ScrobbleQueueItem(trackID: trackID, playedAt: 1, durationPlayed: 30))
        try await repo.markSubmitted(id: id)
        #expect(try await repo.pendingCount() == 0)
    }

    @Test("incrementAttempts bumps the counter")
    func incrementAttempts() async throws {
        let db = try await makeDB()
        let trackID = try await seedTrack(db)
        let repo = ScrobbleRepository(database: db)
        let id = try await repo.enqueue(ScrobbleQueueItem(trackID: trackID, playedAt: 1, durationPlayed: 30))
        try await repo.incrementAttempts(id: id)
        try await repo.incrementAttempts(id: id)
        let pending = try await repo.fetchPending()
        #expect(pending.first?.submissionAttempts == 2)
    }

    @Test("fetchPending orders by played_at ascending")
    func fetchPendingOrder() async throws {
        let db = try await makeDB()
        let t1 = try await seedTrack(db)
        let t2 = try await seedTrack(db)
        let repo = ScrobbleRepository(database: db)
        _ = try await repo.enqueue(ScrobbleQueueItem(trackID: t1, playedAt: 200, durationPlayed: 30))
        _ = try await repo.enqueue(ScrobbleQueueItem(trackID: t2, playedAt: 100, durationPlayed: 30))
        let pending = try await repo.fetchPending()
        #expect(pending.map(\.playedAt) == [100, 200])
    }
}
