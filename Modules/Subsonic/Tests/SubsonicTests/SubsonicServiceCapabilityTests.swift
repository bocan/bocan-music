import Foundation
import Persistence
import SwiftSonic
import Testing
@testable import Subsonic

// MARK: - Stub transport (file-local)

private final class CapabilityStubTransport: HTTPTransport, @unchecked Sendable {
    private var responses: [(Data, Int)] = []
    private(set) var requests: [String] = []

    func enqueue(json: String, statusCode: Int = 200) {
        self.responses.append((Data(json.utf8), statusCode))
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.requests.append(request.url?.path ?? "")
        guard !self.responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let (data, status) = self.responses.removeFirst()
        let resp = HTTPURLResponse(
            url: request.url ?? URL(string: "https://test.local")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, resp)
    }
}

// MARK: - JSON fixtures

private func pingEnvelope(serverType: String = "navidrome", version: String = "0.50.2") -> String {
    """
    {
        "subsonic-response": {
            "status": "ok",
            "version": "1.16.1",
            "type": "\(serverType)",
            "serverVersion": "\(version)",
            "openSubsonic": true
        }
    }
    """
}

/// Build a `getOpenSubsonicExtensions` response advertising the given features.
private func extensionsEnvelope(_ names: [String]) -> String {
    let entries = names
        .map { "{\"name\":\"\($0)\",\"versions\":[1]}" }
        .joined(separator: ",")
    return """
    {
        "subsonic-response": {
            "status": "ok",
            "version": "1.16.1",
            "openSubsonicExtensions": [\(entries)]
        }
    }
    """
}

// MARK: - Helpers

private let testServerURL = URL(string: "https://music.test.local")!

private func makeStore() async throws -> (SubsonicServerStore, SubsonicServerRepository, Database) {
    let db = try await Database(location: .inMemory)
    let repo = SubsonicServerRepository(database: db)
    let store = SubsonicServerStore(repository: repo)
    return (store, repo, db)
}

private func seedServer(repo: SubsonicServerRepository, id: UUID = UUID()) async throws -> UUID {
    let dto = SubsonicServerDTO(
        id: id,
        name: "Test \(id.uuidString.prefix(8))",
        serverURL: testServerURL,
        authKind: "tokenSalt",
        username: "alice",
        keychainAccount: id.uuidString
    )
    try await repo.insert(dto)
    return id
}

private func makeClient(_ transport: HTTPTransport) -> SwiftSonicClient {
    let config = ServerConfiguration(
        serverURL: testServerURL,
        auth: .tokenAuth(username: "alice", password: "s3cr3t", reusesSalt: false)
    )
    return SwiftSonicClient(configuration: config, transport: transport)
}

// MARK: - SubsonicCapabilities flag-comparison

@Suite("SubsonicCapabilities flag comparison")
struct SubsonicCapabilitiesFlagComparisonTests {
    @Test("hasSameCapabilityFlags ignores fetchedAt")
    func ignoresFetchedAt() {
        let a = SubsonicCapabilities(
            serverType: "navidrome",
            serverVersion: "0.50.2",
            apiVersion: "1.16.1",
            isOpenSubsonic: true,
            supportsPodcasts: true,
            fetchedAt: Date(timeIntervalSince1970: 1)
        )
        let b = SubsonicCapabilities(
            serverType: "navidrome",
            serverVersion: "0.50.2",
            apiVersion: "1.16.1",
            isOpenSubsonic: true,
            supportsPodcasts: true,
            fetchedAt: Date(timeIntervalSince1970: 999_999)
        )
        #expect(a.hasSameCapabilityFlags(as: b))
    }

    @Test("detects podcasts flag change")
    func detectsPodcastsChange() {
        let a = SubsonicCapabilities(supportsPodcasts: false)
        let b = SubsonicCapabilities(supportsPodcasts: true)
        #expect(!a.hasSameCapabilityFlags(as: b))
    }

    @Test("detects server version change")
    func detectsVersionChange() {
        let a = SubsonicCapabilities(serverVersion: "0.50.2")
        let b = SubsonicCapabilities(serverVersion: "0.51.0")
        #expect(!a.hasSameCapabilityFlags(as: b))
    }

    @Test("detects each feature flag independently")
    func detectsEachFlag() {
        let base = SubsonicCapabilities()
        let cases: [(String, SubsonicCapabilities)] = [
            ("lyrics", SubsonicCapabilities(supportsLyricsBySongId: true)),
            ("apiKey", SubsonicCapabilities(supportsApiKey: true)),
            ("internetRadio", SubsonicCapabilities(supportsInternetRadio: true)),
            ("bookmarks", SubsonicCapabilities(supportsBookmarks: true)),
            ("jukebox", SubsonicCapabilities(supportsJukebox: true)),
            ("shares", SubsonicCapabilities(supportsShares: true)),
            ("randomSongsByGenre", SubsonicCapabilities(supportsRandomSongsByGenre: true)),
        ]
        for (name, mutated) in cases {
            #expect(!base.hasSameCapabilityFlags(as: mutated), "Flag \(name) should diff")
        }
    }
}

// MARK: - SubsonicServerStore.updateCapabilities

@Suite("SubsonicServerStore.updateCapabilities")
struct SubsonicServerStoreCapabilityTests {
    @Test("writes capabilitiesJSON without touching the Keychain")
    func writesCapabilitiesJSON() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)
        let payload = Data("hello".utf8)

        try await store.updateCapabilities(serverID: id, capabilitiesJSON: payload)

        let fetched = try #require(await repo.fetch(id: id))
        #expect(fetched.capabilitiesJSON == payload)
        #expect(fetched.lastConnectedAt != nil)
    }

    @Test("nil capabilitiesJSON clears the column")
    func clearsCapabilities() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)

        try await store.updateCapabilities(serverID: id, capabilitiesJSON: Data("x".utf8))
        try await store.updateCapabilities(serverID: id, capabilitiesJSON: nil)

        let fetched = try #require(await repo.fetch(id: id))
        #expect(fetched.capabilitiesJSON == nil)
    }
}

// MARK: - SubsonicService capability emission

@Suite("SubsonicService capability stream")
struct SubsonicServiceCapabilityStreamTests {
    @Test("first capability load persists JSON and emits server ID")
    func firstLoadPersistsAndEmits() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)
        let transport = CapabilityStubTransport()
        transport.enqueue(json: pingEnvelope())
        transport.enqueue(json: extensionsEnvelope(["podcasts", "internetRadio"]))

        let service = SubsonicService(store: store)
        await service._registerClientForTesting(makeClient(transport), serverID: id)

        // Subscribe BEFORE triggering work — the stream buffers until consumed.
        let stream = await service.capabilityUpdates

        let caps = try await service.loadCapabilities(serverID: id)
        #expect(caps.supportsPodcasts)
        #expect(caps.supportsInternetRadio)
        #expect(!caps.supportsBookmarks)

        // Drain one emission within a bounded timeout.
        let emitted = try await withThrowingTaskGroup(of: UUID?.self) { group in
            group.addTask {
                for await uuid in stream {
                    return uuid
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(emitted == id)

        // DB now carries the encoded capability snapshot.
        let stored = try #require(await repo.fetch(id: id))
        let json = try #require(stored.capabilitiesJSON)
        let decoded = try JSONDecoder().decode(SubsonicCapabilities.self, from: json)
        #expect(decoded.supportsPodcasts)
        #expect(decoded.supportsInternetRadio)
        #expect(decoded.serverType == "navidrome")
    }

    @Test("refreshCapabilities does not emit when flags are unchanged")
    func refreshDoesNotEmitWhenUnchanged() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)
        let transport = CapabilityStubTransport()
        // Two identical round-trips: ping + extensions × 2.
        for _ in 0 ..< 2 {
            transport.enqueue(json: pingEnvelope())
            transport.enqueue(json: extensionsEnvelope(["podcasts"]))
        }

        let service = SubsonicService(store: store)
        await service._registerClientForTesting(makeClient(transport), serverID: id)

        // Collect emissions throughout the test.
        let stream = await service.capabilityUpdates
        let collector = Task { () -> [UUID] in
            var ids: [UUID] = []
            for await uuid in stream {
                ids.append(uuid)
                if ids.count == 1 { break } // bail after the first; we only expect one.
            }
            return ids
        }

        _ = try await service.loadCapabilities(serverID: id) // emits once
        _ = try await service.refreshCapabilities(serverID: id) // identical → no emit
        try await Task.sleep(nanoseconds: 200_000_000)
        collector.cancel()
        let emissions = await collector.value
        #expect(emissions == [id])
    }

    @Test("refreshCapabilities emits again when flags change")
    func refreshEmitsOnFlagChange() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)
        let transport = CapabilityStubTransport()
        // First load: no podcasts. Second (refresh): podcasts enabled.
        transport.enqueue(json: pingEnvelope())
        transport.enqueue(json: extensionsEnvelope([]))
        transport.enqueue(json: pingEnvelope())
        transport.enqueue(json: extensionsEnvelope(["podcasts", "bookmarks"]))

        let service = SubsonicService(store: store)
        await service._registerClientForTesting(makeClient(transport), serverID: id)

        let stream = await service.capabilityUpdates
        let collector = Task { () -> [UUID] in
            var ids: [UUID] = []
            for await uuid in stream {
                ids.append(uuid)
                if ids.count >= 2 { break }
            }
            return ids
        }

        let first = try await service.loadCapabilities(serverID: id)
        #expect(!first.supportsPodcasts)

        let second = try await service.refreshCapabilities(serverID: id)
        #expect(second.supportsPodcasts)
        #expect(second.supportsBookmarks)

        // Give the collector a moment.
        try await Task.sleep(nanoseconds: 200_000_000)
        collector.cancel()
        let emissions = await collector.value
        #expect(emissions == [id, id])

        // Persisted snapshot reflects the latest.
        let stored = try #require(await repo.fetch(id: id))
        let decoded = try JSONDecoder().decode(SubsonicCapabilities.self, from: #require(stored.capabilitiesJSON))
        #expect(decoded.supportsPodcasts)
        #expect(decoded.supportsBookmarks)
    }

    @Test("loadCapabilities returns cached value on second call without re-emitting")
    func cachedLoadDoesNotEmit() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)
        let transport = CapabilityStubTransport()
        transport.enqueue(json: pingEnvelope())
        transport.enqueue(json: extensionsEnvelope(["jukebox"]))

        let service = SubsonicService(store: store)
        await service._registerClientForTesting(makeClient(transport), serverID: id)

        let stream = await service.capabilityUpdates
        let collector = Task { () -> Int in
            var count = 0
            for await _ in stream {
                count += 1
                if count >= 2 { break }
            }
            return count
        }

        _ = try await service.loadCapabilities(serverID: id)
        _ = try await service.loadCapabilities(serverID: id)
        try await Task.sleep(nanoseconds: 200_000_000)
        collector.cancel()
        #expect(await collector.value == 1)
        // Only the first ping+extensions pair was consumed.
        #expect(transport.requests.count == 2)
    }
}
