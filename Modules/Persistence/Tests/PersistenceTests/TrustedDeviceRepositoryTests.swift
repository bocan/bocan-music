import Foundation
import Testing
@testable import Persistence

@Suite("TrustedDeviceRepository")
struct TrustedDeviceRepositoryTests {
    private static func sample(
        fingerprint: String,
        name: String = "Test Phone",
        pairedAt: Double = 1000
    ) -> TrustedDevice {
        TrustedDevice(
            fingerprint: fingerprint,
            certDER: Data([0x30, 0x82, 0x01, 0x02]),
            deviceName: name,
            pairedAt: pairedAt
        )
    }

    @Test("upsert then all round-trips the device")
    func upsertRoundTrips() async throws {
        let db = try await Database(location: .inMemory)
        let repo = TrustedDeviceRepository(database: db)

        try await repo.upsert(Self.sample(fingerprint: "aa"))
        let all = try await repo.all()

        #expect(all.count == 1)
        #expect(all.first?.fingerprint == "aa")
        #expect(all.first?.deviceName == "Test Phone")
    }

    @Test("contains reflects membership")
    func containsReflectsMembership() async throws {
        let db = try await Database(location: .inMemory)
        let repo = TrustedDeviceRepository(database: db)

        #expect(try await repo.contains(fingerprint: "aa") == false)
        try await repo.upsert(Self.sample(fingerprint: "aa"))
        #expect(try await repo.contains(fingerprint: "aa") == true)
    }

    @Test("upsert on the same fingerprint replaces rather than duplicates")
    func upsertReplaces() async throws {
        let db = try await Database(location: .inMemory)
        let repo = TrustedDeviceRepository(database: db)

        try await repo.upsert(Self.sample(fingerprint: "aa", name: "Old", pairedAt: 1))
        try await repo.upsert(Self.sample(fingerprint: "aa", name: "New", pairedAt: 2))

        let all = try await repo.all()
        #expect(all.count == 1)
        #expect(all.first?.deviceName == "New")
        #expect(all.first?.pairedAt == 2)
    }

    @Test("all orders by paired_at descending")
    func allOrdersByPairedAt() async throws {
        let db = try await Database(location: .inMemory)
        let repo = TrustedDeviceRepository(database: db)

        try await repo.upsert(Self.sample(fingerprint: "old", pairedAt: 10))
        try await repo.upsert(Self.sample(fingerprint: "new", pairedAt: 20))

        let all = try await repo.all()
        #expect(all.map(\.fingerprint) == ["new", "old"])
    }

    @Test("delete removes the device")
    func deleteRemoves() async throws {
        let db = try await Database(location: .inMemory)
        let repo = TrustedDeviceRepository(database: db)

        try await repo.upsert(Self.sample(fingerprint: "aa"))
        try await repo.delete(fingerprint: "aa")

        #expect(try await repo.all().isEmpty)
        #expect(try await repo.contains(fingerprint: "aa") == false)
    }

    @Test("observeAll emits on insert and delete")
    func observeAllEmits() async throws {
        let db = try await Database(location: .inMemory)
        let repo = TrustedDeviceRepository(database: db)
        var iterator = await repo.observeAll().makeAsyncIterator()

        let initial = try await iterator.next()
        #expect(initial?.isEmpty == true)

        try await repo.upsert(Self.sample(fingerprint: "aa"))
        let afterInsert = try await iterator.next()
        #expect(afterInsert?.count == 1)

        try await repo.delete(fingerprint: "aa")
        let afterDelete = try await iterator.next()
        #expect(afterDelete?.isEmpty == true)
    }
}
