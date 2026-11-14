import Foundation
import Persistence
import Testing
@testable import Jellyfin

@Suite("JellyfinAnnotations", .serialized)
struct JellyfinAnnotationsTests {
    private struct Harness {
        let annotations: JellyfinAnnotations
        let stub: StubJellyfinClient
        let serverID: UUID
        let events: Locked<[JellyfinAnnotations.Event]>
        let reader: Task<Void, Never>
    }

    private func makeHarness(syncStars: Bool = true) async throws -> Harness {
        let database = try await Persistence.Database(location: .inMemory)
        let repository = JellyfinServerRepository(database: database)
        let store = JellyfinServerStore(
            repository: repository,
            keychainService: "io.cloudcauldron.bocan.jellyfin.test.\(UUID().uuidString)"
        )
        let id = UUID()
        try await repository.insert(JellyfinServerDTO(
            id: id,
            name: "Home-\(id.uuidString.prefix(6))",
            serverURL: URL(string: "https://jf.example.test") ?? URL(filePath: "/"),
            userID: "user-1",
            deviceID: "DEVICE-1",
            syncStars: syncStars
        ))
        let stub = StubJellyfinClient()
        let service = JellyfinService(
            store: store,
            identity: JellyfinClientIdentity(client: "Bocan", deviceName: "Test", version: "1")
        ) { _ in stub }
        await service.registerClientForTesting(stub, serverID: id)
        let annotations = JellyfinAnnotations(service: service, retryDelay: .milliseconds(10))
        let events = Locked<[JellyfinAnnotations.Event]>([])
        let stream = await annotations.events
        let reader = Task {
            for await event in stream {
                events.update { $0.append(event) }
            }
        }
        return Harness(annotations: annotations, stub: stub, serverID: id, events: events, reader: reader)
    }

    @Test("a favourite is delivered once and raises no event")
    func delivered() async throws {
        let harness = try await self.makeHarness()
        await harness.annotations.star(serverID: harness.serverID, itemID: "i1")
        #expect(harness.stub.favorites.value.map(\.itemID) == ["i1"])
        #expect(harness.stub.favorites.value.map(\.isFavorite) == [true])
        try await Task.sleep(for: .milliseconds(80))
        #expect(harness.stub.favorites.value.count == 1)
        #expect(harness.events.value.isEmpty)
        harness.reader.cancel()
    }

    @Test("an unfavourite is delivered as false")
    func unstar() async throws {
        let harness = try await self.makeHarness()
        await harness.annotations.unstar(serverID: harness.serverID, itemID: "i1")
        #expect(harness.stub.favorites.value.map(\.isFavorite) == [false])
        harness.reader.cancel()
    }

    @Test("with syncStars off nothing is sent, nothing is queued and no event is raised")
    func syncStarsOff() async throws {
        let harness = try await self.makeHarness(syncStars: false)
        await harness.annotations.star(serverID: harness.serverID, itemID: "i1")
        await harness.annotations.unstar(serverID: harness.serverID, itemID: "i1")
        try await Task.sleep(for: .milliseconds(80))
        #expect(harness.stub.favorites.value.isEmpty)
        #expect(harness.events.value.isEmpty)
        harness.reader.cancel()
    }

    @Test("a failure is retried and a later success ends the retries quietly")
    func retrySucceeds() async throws {
        let harness = try await self.makeHarness()
        let attempts = Locked(0)
        harness.stub.onSetFavorite = { _, _ in
            var current = 0
            attempts.update { $0 += 1
                current = $0
            }
            if current < 3 {
                throw JellyfinError.network("down")
            }
        }
        await harness.annotations.star(serverID: harness.serverID, itemID: "i1")
        #expect(await eventually { harness.stub.favorites.value.count == 3 })
        try await Task.sleep(for: .milliseconds(80))
        #expect(harness.stub.favorites.value.count == 3)
        #expect(harness.events.value.isEmpty)
        harness.reader.cancel()
    }

    @Test("three failures raise one annotationFailed event and stop")
    func exhausted() async throws {
        let harness = try await self.makeHarness()
        harness.stub.onSetFavorite = { _, _ in throw JellyfinError.http(status: 500) }
        await harness.annotations.star(serverID: harness.serverID, itemID: "i1")
        #expect(await eventually { harness.events.value.count == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.stub.favorites.value.count == 3)
        #expect(harness.events.value.count == 1)
        if case let .annotationFailed(serverID, itemID, _) = harness.events.value[0] {
            #expect(serverID == harness.serverID)
            #expect(itemID == "i1")
        } else {
            Issue.record("expected annotationFailed")
        }
        harness.reader.cancel()
    }

    @Test("a favourite then an unfavourite before delivery leaves only the last action")
    func collapse() async throws {
        let harness = try await self.makeHarness()
        // The first attempt of the favourite fails; the user then unfavourites at once.
        harness.stub.onSetFavorite = { _, isFavorite in
            if isFavorite {
                throw JellyfinError.network("down")
            }
        }
        await harness.annotations.star(serverID: harness.serverID, itemID: "i1")
        await harness.annotations.unstar(serverID: harness.serverID, itemID: "i1")
        try await Task.sleep(for: .milliseconds(150))
        // The favourite was tried once. Its retry was dropped because the unfavourite replaced it.
        #expect(harness.stub.favorites.value.map(\.isFavorite) == [true, false])
        #expect(harness.events.value.isEmpty)
        harness.reader.cancel()
    }

    @Test("an overtaken action that would have failed for good raises no event")
    func overtakenActionRaisesNoEvent() async throws {
        let harness = try await self.makeHarness()
        harness.stub.onSetFavorite = { _, isFavorite in
            if isFavorite {
                throw JellyfinError.http(status: 500)
            }
        }
        await harness.annotations.star(serverID: harness.serverID, itemID: "i1")
        await harness.annotations.unstar(serverID: harness.serverID, itemID: "i1")
        try await Task.sleep(for: .milliseconds(150))
        #expect(harness.events.value.isEmpty)
        harness.reader.cancel()
    }

    @Test("different items do not collapse into each other")
    func separateItems() async throws {
        let harness = try await self.makeHarness()
        await harness.annotations.star(serverID: harness.serverID, itemID: "i1")
        await harness.annotations.unstar(serverID: harness.serverID, itemID: "i2")
        #expect(harness.stub.favorites.value.map(\.itemID) == ["i1", "i2"])
        harness.reader.cancel()
    }
}
