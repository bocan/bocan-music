// swiftlint:disable file_length
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

/// Names the legacy-core capabilities SubsonicService probes after fetching
/// the OpenSubsonic extensions list. Probe order is radio → podcasts → bookmarks.
private enum LegacyCoreProbe { case internetRadio, podcasts, bookmarks }

/// Enqueues an HTTP 404 ("not supported") for each probe SubsonicService is
/// expected to run during a single capability load. Pass only the probes you
/// expect to fire — anything advertised in extensions is skipped by the
/// service.
private func enqueueProbeFailures(_ transport: CapabilityStubTransport, for probes: [LegacyCoreProbe]) {
    for _ in probes {
        transport.enqueue(json: "", statusCode: 404)
    }
}

/// JSON envelope for a successful (but empty) `getInternetRadioStations` response.
private func emptyRadioStationsEnvelope() -> String {
    """
    {"subsonic-response":{"status":"ok","version":"1.16.1","internetRadioStations":{"internetRadioStation":[]}}}
    """
}

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
        // podcasts and internetRadio are advertised → probe is skipped for both.
        // Only bookmarks probe runs; have it return 404 so caps.supportsBookmarks stays false.
        enqueueProbeFailures(transport, for: [.bookmarks])

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
        // Two identical round-trips: ping + extensions + probes × 2.
        // podcasts is advertised → skipped. radio + bookmarks probes run; 404 both.
        for _ in 0 ..< 2 {
            transport.enqueue(json: pingEnvelope())
            transport.enqueue(json: extensionsEnvelope(["podcasts"]))
            enqueueProbeFailures(transport, for: [.internetRadio, .bookmarks])
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
        // First load: no extensions. All 3 probes run, all return 404.
        transport.enqueue(json: pingEnvelope())
        transport.enqueue(json: extensionsEnvelope([]))
        enqueueProbeFailures(transport, for: [.internetRadio, .podcasts, .bookmarks])
        // Second (refresh): podcasts + bookmarks advertised, only radio probe runs (404).
        transport.enqueue(json: pingEnvelope())
        transport.enqueue(json: extensionsEnvelope(["podcasts", "bookmarks"]))
        enqueueProbeFailures(transport, for: [.internetRadio])

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

    @Test("legacy-core probe flips supportsInternetRadio to true when server answers 200")
    func probePromotesUnadvertisedCapability() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)
        let transport = CapabilityStubTransport()
        // No legacy-core capability is advertised. Probe runs for all 3.
        transport.enqueue(json: pingEnvelope())
        transport.enqueue(json: extensionsEnvelope([]))
        // Radio probe returns 200 (empty list) → supportsInternetRadio should flip to true.
        transport.enqueue(json: emptyRadioStationsEnvelope())
        // Podcasts + bookmarks probes return 404 → those flags stay false.
        enqueueProbeFailures(transport, for: [.podcasts, .bookmarks])

        let service = SubsonicService(store: store)
        await service._registerClientForTesting(makeClient(transport), serverID: id)

        let caps = try await service.loadCapabilities(serverID: id)
        #expect(caps.supportsInternetRadio, "200 from getInternetRadioStations should set the flag")
        #expect(!caps.supportsPodcasts)
        #expect(!caps.supportsBookmarks)
    }

    @Test("legacy-core probe skips capabilities already advertised in extensions")
    func probeSkipsAdvertised() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)
        let transport = CapabilityStubTransport()
        // All 3 legacy-core capabilities advertised — no probe should fire.
        transport.enqueue(json: pingEnvelope())
        transport.enqueue(json: extensionsEnvelope(["internetRadio", "podcasts", "bookmarks"]))

        let service = SubsonicService(store: store)
        await service._registerClientForTesting(makeClient(transport), serverID: id)

        let caps = try await service.loadCapabilities(serverID: id)
        #expect(caps.supportsInternetRadio)
        #expect(caps.supportsPodcasts)
        #expect(caps.supportsBookmarks)
        // Exactly 2 requests went over the wire — no probe round-trips.
        #expect(transport.requests.count == 2)
    }

    @Test("transient probe error leaves the existing flag untouched")
    func probeTransientErrorDoesNotDowngrade() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)
        let transport = CapabilityStubTransport()
        // No extensions; all 3 probes will run. Queue runs out before podcasts probe,
        // surfacing as URLError(.badServerResponse) — a transient signal, not a lie.
        transport.enqueue(json: pingEnvelope())
        transport.enqueue(json: extensionsEnvelope([]))
        transport.enqueue(json: "", statusCode: 404) // radio: capability lie → false (already false)
        // No more responses → podcasts + bookmarks probes throw URLError → no override.

        let service = SubsonicService(store: store)
        await service._registerClientForTesting(makeClient(transport), serverID: id)

        let caps = try await service.loadCapabilities(serverID: id)
        // The lie response on radio set it explicitly false; podcasts + bookmarks
        // saw a transient error so they retain their pre-probe value (also false).
        #expect(!caps.supportsInternetRadio)
        #expect(!caps.supportsPodcasts)
        #expect(!caps.supportsBookmarks)
    }

    @Test("loadCapabilities returns cached value on second call without re-emitting")
    func cachedLoadDoesNotEmit() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)
        let transport = CapabilityStubTransport()
        transport.enqueue(json: pingEnvelope())
        transport.enqueue(json: extensionsEnvelope(["jukebox"]))
        // Jukebox advertised; none of the legacy-core probes are skipped → all 3 run (404).
        enqueueProbeFailures(transport, for: [.internetRadio, .podcasts, .bookmarks])

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
        // First load consumed ping + extensions + 3 probes; second was served from cache.
        #expect(transport.requests.count == 5)
    }
}

// MARK: - Capability lie detection tests

// MARK: Additional JSON fixtures

/// Subsonic "status: failed" envelope — simulates a server returning API error `code`.
private func apiErrorEnvelope(code: Int, message: String = "Error") -> String {
    """
    {
        "subsonic-response": {
            "status": "failed",
            "version": "1.16.1",
            "error": {
                "code": \(code),
                "message": "\(message)"
            }
        }
    }
    """
}

/// A `SwiftSonicClient` with `RetryPolicy.none` so transient-looking errors
/// (e.g. HTTP 501) are thrown immediately without retries in tests.
private func makeClientNoRetry(_ transport: HTTPTransport) -> SwiftSonicClient {
    let config = ServerConfiguration(
        serverURL: testServerURL,
        auth: .tokenAuth(username: "alice", password: "s3cr3t", reusesSalt: false)
    )
    return SwiftSonicClient(configuration: config, transport: transport, retryPolicy: .none)
}

// MARK: - SubsonicService capability lie detection

@Suite("SubsonicService capability lie detection")
struct SubsonicServiceCapabilityLieTests {
    @Test("getPodcasts HTTP 404 revokes podcasts capability and emits on capabilityUpdates")
    func getPodcasts404RevokesCapability() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)
        let transport = CapabilityStubTransport()
        // Capability load: podcasts advertised. Probes run for radio + bookmarks (skipped for podcasts).
        transport.enqueue(json: pingEnvelope())
        transport.enqueue(json: extensionsEnvelope(["podcasts"]))
        enqueueProbeFailures(transport, for: [.internetRadio, .bookmarks])
        // getPodcasts returns HTTP 404.
        transport.enqueue(json: "", statusCode: 404)

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

        // Load capabilities (first emission).
        let caps = try await service.loadCapabilities(serverID: id)
        #expect(caps.supportsPodcasts)

        // getPodcasts throws but side-effects a capability revocation (second emission).
        do {
            _ = try await service.getPodcasts(serverID: id)
            Issue.record("Expected getPodcasts to throw on HTTP 404")
        } catch {}

        try await Task.sleep(nanoseconds: 200_000_000)
        collector.cancel()
        #expect(await collector.value == [id, id], "Expect 2 emissions: initial load + revocation")

        // In-memory capability is now false.
        let updated = await service._capabilitiesForTesting(serverID: id)
        #expect(updated?.supportsPodcasts == false)

        // Persisted snapshot also reflects revocation.
        let stored = try #require(await repo.fetch(id: id))
        let decoded = try JSONDecoder().decode(SubsonicCapabilities.self, from: #require(stored.capabilitiesJSON))
        #expect(!decoded.supportsPodcasts)
    }

    @Test("getBookmarks Subsonic API error 70 revokes bookmarks capability and emits")
    func getBookmarksNotFoundRevokesCapability() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)
        let transport = CapabilityStubTransport()
        transport.enqueue(json: pingEnvelope())
        transport.enqueue(json: extensionsEnvelope(["bookmarks"]))
        // Bookmarks advertised → bookmarks probe skipped; radio + podcasts probes run.
        enqueueProbeFailures(transport, for: [.internetRadio, .podcasts])
        // getBookmarks returns Subsonic API error 70 (notFound).
        transport.enqueue(json: apiErrorEnvelope(code: 70, message: "Data not found"))

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

        let caps = try await service.loadCapabilities(serverID: id)
        #expect(caps.supportsBookmarks)

        do {
            _ = try await service.getBookmarks(serverID: id)
            Issue.record("Expected getBookmarks to throw on API error 70")
        } catch {}

        try await Task.sleep(nanoseconds: 200_000_000)
        collector.cancel()
        #expect(await collector.value == [id, id])

        let updated = await service._capabilitiesForTesting(serverID: id)
        #expect(updated?.supportsBookmarks == false)
    }

    @Test("getInternetRadioStations HTTP 501 revokes internetRadio capability and emits")
    func getInternetRadio501RevokesCapability() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)
        let transport = CapabilityStubTransport()
        transport.enqueue(json: pingEnvelope())
        transport.enqueue(json: extensionsEnvelope(["internetRadio"]))
        // internetRadio advertised → radio probe skipped; podcasts + bookmarks probes run.
        enqueueProbeFailures(transport, for: [.podcasts, .bookmarks])
        // Server returns 501 Not Implemented (use no-retry client to avoid slow retries).
        transport.enqueue(json: "", statusCode: 501)

        let service = SubsonicService(store: store)
        // No-retry so the 501 isn't retried (5xx is "transient" in the default policy).
        await service._registerClientForTesting(makeClientNoRetry(transport), serverID: id)

        let stream = await service.capabilityUpdates
        let collector = Task { () -> [UUID] in
            var ids: [UUID] = []
            for await uuid in stream {
                ids.append(uuid)
                if ids.count >= 2 { break }
            }
            return ids
        }

        let caps = try await service.loadCapabilities(serverID: id)
        #expect(caps.supportsInternetRadio)

        do {
            _ = try await service.getInternetRadioStations(serverID: id)
            Issue.record("Expected getInternetRadioStations to throw on HTTP 501")
        } catch {}

        try await Task.sleep(nanoseconds: 200_000_000)
        collector.cancel()
        #expect(await collector.value == [id, id])

        let updated = await service._capabilitiesForTesting(serverID: id)
        #expect(updated?.supportsInternetRadio == false)
    }

    @Test("network error on getPodcasts does not revoke podcasts capability")
    func networkErrorDoesNotRevokeCapability() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)
        let transport = CapabilityStubTransport()
        transport.enqueue(json: pingEnvelope())
        transport.enqueue(json: extensionsEnvelope(["podcasts"]))
        // No response queued for getPodcasts → throws URLError (treated as network error).

        let service = SubsonicService(store: store)
        await service._registerClientForTesting(makeClientNoRetry(transport), serverID: id)

        let stream = await service.capabilityUpdates
        let collector = Task { () -> Int in
            var count = 0
            for await _ in stream {
                count += 1
                if count >= 2 { break }
            }
            return count
        }

        let caps = try await service.loadCapabilities(serverID: id)
        #expect(caps.supportsPodcasts)

        do {
            _ = try await service.getPodcasts(serverID: id)
            Issue.record("Expected getPodcasts to throw on network error")
        } catch {}

        try await Task.sleep(nanoseconds: 200_000_000)
        collector.cancel()
        // Only the initial capability load should have emitted; no revocation.
        #expect(await collector.value == 1, "Network error must not trigger a revocation emission")

        let updated = await service._capabilitiesForTesting(serverID: id)
        #expect(updated?.supportsPodcasts == true, "Network error must not revoke podcasts capability")
    }

    @Test("capability revocation is no-op when flag is already false")
    func idempotentRevocation() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)
        let transport = CapabilityStubTransport()
        // No podcasts extension advertised → supportsPodcasts = false after load.
        transport.enqueue(json: pingEnvelope())
        transport.enqueue(json: extensionsEnvelope([]))
        transport.enqueue(json: "", statusCode: 404)

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

        let caps = try await service.loadCapabilities(serverID: id)
        #expect(!caps.supportsPodcasts)

        // 404 fires markCapabilityUnsupported but the flag is already false — no emit.
        do { _ = try await service.getPodcasts(serverID: id) } catch {}

        try await Task.sleep(nanoseconds: 200_000_000)
        collector.cancel()
        #expect(await collector.value == 1, "Only the initial load should emit; revocation is a no-op")
    }

    @Test("capability revocation is no-op when no capabilities snapshot exists")
    func noSnapshotRevocationIsNoOp() async throws {
        let (store, repo, _) = try await makeStore()
        let id = try await seedServer(repo: repo)
        let transport = CapabilityStubTransport()
        // Capabilities never loaded — the first call is getPodcasts which 404s.
        transport.enqueue(json: "", statusCode: 404)

        let service = SubsonicService(store: store)
        await service._registerClientForTesting(makeClient(transport), serverID: id)

        let stream = await service.capabilityUpdates
        let collector = Task { () -> Int in
            var count = 0
            for await _ in stream {
                count += 1
                if count >= 1 { break }
            }
            return count
        }

        do { _ = try await service.getPodcasts(serverID: id) } catch {}

        try await Task.sleep(nanoseconds: 200_000_000)
        collector.cancel()
        #expect(await collector.value == 0, "No emit when there is no capability snapshot to downgrade")
        _ = repo // suppress unused warning
    }
}
