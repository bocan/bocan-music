import Foundation
import Network
import os
import Persistence
import Testing
@testable import SyncServer

/// A pairing bridge that trusts nothing on its own; lifecycle tests seed trust
/// directly in the database.
private final class NoopUIBridge: PairingUIBridge, @unchecked Sendable {
    func showCode(_: String) async {}
    func requestConfirmation(deviceName _: String, fingerprintTail _: String) async -> Bool {
        false
    }

    func pairingEnded(result _: PairingResult) async {}
}

@Suite("SyncServer lifecycle")
struct SyncServerLifecycleTests {
    /// A running `SyncServer` with a client whose cert is pre-trusted in the db.
    private struct Harness {
        let server: SyncServer
        let client: LoopbackClient
        let serverStore: KeychainIdentityStore
        let clientStore: KeychainIdentityStore

        func teardown() async {
            await self.server.stop()
            self.serverStore.deleteAll()
            self.clientStore.deleteAll()
        }
    }

    private func makeHarness(serverName: String = "TestMac") async throws -> Harness {
        let database = try await Database(location: .inMemory)
        let serverStore = KeychainIdentityStore(service: "io.cloudcauldron.bocan.sync.test.lifecycle.server.\(UUID().uuidString)")
        let clientStore = KeychainIdentityStore(service: "io.cloudcauldron.bocan.sync.test.lifecycle.client.\(UUID().uuidString)")
        let serverIdentity = ServerIdentity(store: serverStore)

        // Pre-trust the client by persisting its fingerprint, mirroring a prior pairing.
        let clientMaterial = try clientStore.loadOrCreate()
        let clientIdentity = try clientStore.secIdentity(for: clientMaterial)
        let clientFingerprint = ServerFingerprint(certificateDER: clientMaterial.certificateDER).hex
        try await TrustedDeviceRepository(database: database).upsert(TrustedDevice(
            fingerprint: clientFingerprint,
            certDER: clientMaterial.certificateDER,
            deviceName: "Test Phone",
            pairedAt: 0
        ))

        let server = SyncServer(
            database: database,
            identity: serverIdentity,
            ui: NoopUIBridge(),
            serverName: { serverName },
            config: SyncServerConfig(changeDebounce: .milliseconds(50))
        )
        return Harness(
            server: server,
            client: LoopbackClient(clientIdentity: clientIdentity),
            serverStore: serverStore,
            clientStore: clientStore
        )
    }

    @Test("start binds a port a trusted client can ping, and stop closes it")
    func startPingStop() async throws {
        let harness = try await self.makeHarness()
        defer { harness.serverStore.deleteAll()
            harness.clientStore.deleteAll()
        }

        try await harness.server.start()
        let running = await harness.server.isRunning
        #expect(running)
        let port = try #require(await harness.server.port)
        #expect(port != 0)

        let ping = try await harness.client.request(port: port, path: "/v1/ping")
        #expect(ping.status == 200)

        await harness.server.stop()
        let stillRunning = await harness.server.isRunning
        #expect(!stillRunning)
        let clearedPort = await harness.server.port
        #expect(clearedPort == nil)

        // The listener is closed: a fresh connect to the old port fails.
        await #expect(throws: (any Error).self) {
            _ = try await harness.client.request(port: port, path: "/v1/ping")
        }
    }

    @Test("start and stop are idempotent")
    func idempotent() async throws {
        let harness = try await self.makeHarness()
        defer { Task { await harness.teardown() } }

        try await harness.server.start()
        let firstPort = await harness.server.port
        try await harness.server.start() // no-op
        let secondPort = await harness.server.port
        #expect(firstPort == secondPort)

        await harness.server.stop()
        await harness.server.stop() // no-op
        let running = await harness.server.isRunning
        #expect(!running)
    }

    @Test("reAdvertise after a simulated wake keeps the server serving")
    func reAdvertiseAfterWake() async throws {
        let harness = try await self.makeHarness()
        defer { Task { await harness.teardown() } }

        try await harness.server.start()
        await harness.server.reAdvertise()

        let port = try #require(await harness.server.port)
        let ping = try await harness.client.request(port: port, path: "/v1/ping")
        #expect(ping.status == 200)
    }
}
