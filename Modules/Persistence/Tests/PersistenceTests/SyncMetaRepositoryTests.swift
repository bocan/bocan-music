import Foundation
import Testing
@testable import Persistence

@Suite("SyncMetaRepository")
struct SyncMetaRepositoryTests {
    @Test("serverId is minted once and stable across reads")
    func serverIdStable() async throws {
        let database = try await Database(location: .inMemory)
        let repo = SyncMetaRepository(database: database)
        let first = try await repo.serverId()
        let second = try await repo.serverId()
        #expect(!first.isEmpty)
        #expect(first == second)
    }

    @Test("generation starts at zero and increments")
    func generationBumps() async throws {
        let database = try await Database(location: .inMemory)
        let repo = SyncMetaRepository(database: database)
        #expect(try await repo.generation() == 0)
        #expect(try await repo.bumpGeneration() == 1)
        #expect(try await repo.bumpGeneration() == 2)
        #expect(try await repo.generation() == 2)
    }

    @Test("bumping generation preserves the server id")
    func bumpPreservesServerId() async throws {
        let database = try await Database(location: .inMemory)
        let repo = SyncMetaRepository(database: database)
        let identifier = try await repo.serverId()
        _ = try await repo.bumpGeneration()
        #expect(try await repo.serverId() == identifier)
    }
}

@Suite("SyncProfileRepository")
struct SyncProfileRepositoryTests {
    @Test("profile JSON round-trips and updates in place")
    func roundTrip() async throws {
        let database = try await Database(location: .inMemory)
        let repo = SyncProfileRepository(database: database)
        #expect(try await repo.profileJSON() == nil)

        let everything = Data("{\"kind\":\"everything\"}".utf8)
        try await repo.setProfileJSON(everything)
        #expect(try await repo.profileJSON() == everything)

        let selected = Data("{\"kind\":\"selected\"}".utf8)
        try await repo.setProfileJSON(selected)
        #expect(try await repo.profileJSON() == selected)
    }
}
