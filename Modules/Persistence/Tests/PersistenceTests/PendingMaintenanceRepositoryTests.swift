import Foundation
import Testing
@testable import Persistence

@Suite("PendingMaintenanceRepository")
struct PendingMaintenanceRepositoryTests {
    @Test("request, hasRequest, duplicate ignore, and clear round-trip (#425)")
    func roundTrip() async throws {
        let db = try await Database(location: .inMemory)
        let repo = PendingMaintenanceRepository(database: db)
        let task = PendingMaintenance.Task.fullRescan

        // M045 leaves one request behind on a fresh database.
        #expect(try await repo.hasRequest(task: task))
        try await repo.clear(task: task)
        #expect(try await repo.hasRequest(task: task) == false)

        try await repo.request(task: task, requestedBy: "test_a", now: Date(timeIntervalSince1970: 10))
        try await repo.request(task: task, requestedBy: "test_b", now: Date(timeIntervalSince1970: 20))
        try await repo.request(task: task, requestedBy: "test_a", now: Date(timeIntervalSince1970: 30))
        let requests = try await repo.requests(task: task)
        #expect(requests.map(\.requestedBy) == ["test_a", "test_b"])
        #expect(requests.first?.requestedAt == 10, "duplicate request is ignored, original stays")
        #expect(try await repo.hasRequest(task: "something_else") == false)

        try await repo.clear(task: task)
        #expect(try await repo.requests(task: task).isEmpty)
    }
}
