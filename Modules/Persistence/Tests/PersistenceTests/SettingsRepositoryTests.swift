import Foundation
import Testing
@testable import Persistence

@Suite("SettingsRepository")
struct SettingsRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    @Test("set and get round-trip codable value")
    func roundTrip() async throws {
        let db = try await makeDB()
        let repo = SettingsRepository(database: db)
        try await repo.set(42, for: "answer")
        let value = try await repo.get(Int.self, for: "answer")
        #expect(value == 42)
    }

    @Test("set overwrites previous value")
    func overwrite() async throws {
        let db = try await makeDB()
        let repo = SettingsRepository(database: db)
        try await repo.set("first", for: "k")
        try await repo.set("second", for: "k")
        #expect(try await repo.get(String.self, for: "k") == "second")
    }

    @Test("get returns nil for missing key")
    func missing() async throws {
        let db = try await makeDB()
        let repo = SettingsRepository(database: db)
        #expect(try await repo.get(Int.self, for: "missing") == nil)
    }

    @Test("remove deletes value")
    func removeKey() async throws {
        let db = try await makeDB()
        let repo = SettingsRepository(database: db)
        try await repo.set("v", for: "k")
        try await repo.remove(key: "k")
        #expect(try await repo.get(String.self, for: "k") == nil)
    }

    @Test("set struct round-trip")
    func setStruct() async throws {
        struct Payload: Codable, Sendable, Equatable {
            let n: Int
            let s: String
        }
        let db = try await makeDB()
        let repo = SettingsRepository(database: db)
        try await repo.set(Payload(n: 7, s: "hi"), for: "payload")
        let loaded = try await repo.get(Payload.self, for: "payload")
        #expect(loaded == Payload(n: 7, s: "hi"))
    }
}
