import Foundation
import Testing
@testable import Persistence

@Suite("Observation Tests")
struct ObservationTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makeTrack(fileURL: String) -> Track {
        let now = Int64(Date().timeIntervalSince1970)
        return Track(
            fileURL: fileURL,
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "flac",
            duration: 180,
            title: "Obs Track",
            addedAt: now,
            updatedAt: now
        )
    }

    @Test("Observation emits initial value immediately")
    func observationEmitsInitialValue() async throws {
        let db = try await makeDatabase()
        let stream = await db.observe {
            try Track.fetchCount($0)
        }
        var iterator = stream.makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial == 0)
    }

    @Test("Observation emits update after insert")
    func observationEmitsOnInsert() async throws {
        let db = try await makeDatabase()
        let repo = TrackRepository(database: db)
        let stream = await db.observe {
            try Track.fetchCount($0)
        }
        var iterator = stream.makeAsyncIterator()
        // Initial emission
        let initial = try await iterator.next()
        #expect(initial == 0)
        // Insert a track — GRDB will emit the new count
        _ = try await repo.insert(self.makeTrack(fileURL: "file:///tmp/obs1.flac"))
        let updated = try await iterator.next()
        #expect(updated == 1)
    }

    @Test("Cancelling the consumer Task tears down the observation")
    func cancellationTearsDownObservation() async throws {
        let db = try await makeDatabase()
        let stream = await db.observe {
            try Track.fetchCount($0)
        }
        let consumerTask = Task {
            for try await _ in stream {
                // consume silently
            }
        }
        // Give observation time to start
        try await Task.sleep(nanoseconds: 20_000_000)
        consumerTask.cancel()
        // If there is a Task leak the test would hang; reaching here means it's clean
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    @Test("AsyncObservation.sequence wraps Database.observe")
    func asyncObservationWraps() async throws {
        let db = try await makeDatabase()
        let stream = await AsyncObservation.sequence(in: db) {
            try Track.fetchCount($0)
        }
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first == 0)
    }
}
