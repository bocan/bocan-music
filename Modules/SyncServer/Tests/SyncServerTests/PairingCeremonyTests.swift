import Foundation
import Persistence
import Testing
@testable import SyncServer

/// A pairing UI bridge that always confirms (the human clicks Trust).
private final class AutoTrustUIBridge: PairingUIBridge, @unchecked Sendable {
    func showCode(_: String) async {}
    func requestConfirmation(deviceName _: String, fingerprintTail _: String) async -> Bool {
        true
    }

    func pairingEnded(result _: PairingResult) async {}
}

@Suite("Pairing ceremony")
struct PairingCeremonyTests {
    @Test("full ceremony over loopback TLS pairs the phone, admits it, and revocation blocks it")
    func fullCeremony() async throws {
        let serverStore = KeychainIdentityStore(service: "io.cloudcauldron.bocan.sync.test.server.\(UUID().uuidString)")
        let clientStore = KeychainIdentityStore(service: "io.cloudcauldron.bocan.sync.test.client.\(UUID().uuidString)")
        defer {
            serverStore.deleteAll()
            clientStore.deleteAll()
        }

        let serverIdentity = ServerIdentity(store: serverStore)
        let serverFingerprint = try await serverIdentity.fingerprint().hex
        let clientMaterial = try clientStore.loadOrCreate()
        let clientIdentity = try clientStore.secIdentity(for: clientMaterial)
        let clientFingerprint = ServerFingerprint(certificateDER: clientMaterial.certificateDER).hex

        let database = try await Database(location: .inMemory)
        let trusted = TrustedDevices(repository: TrustedDeviceRepository(database: database))
        try await trusted.start()

        let coordinator = PairingCoordinator(
            identity: serverIdentity,
            trusted: trusted,
            ui: AutoTrustUIBridge(),
            serverName: { "Test Mac" },
            serverId: { "server-xyz" }
        )
        await coordinator.arm()

        let router = Router(routes:
            PairingRoutes.routes(coordinator: coordinator) +
                [SyncRoutes.ping(serverId: { "server-xyz" }, generation: { 1 })])

        let listener = SyncListener(
            identity: serverIdentity,
            router: router,
            trusted: trusted.fingerprints,
            pairingMode: { coordinator.pairingMode.isOn }
        )
        let port = try await listener.start()
        defer { Task { await listener.stop() } }

        let client = LoopbackClient(clientIdentity: clientIdentity)

        // Step 1: /v1/pair/start (admitted because pairing mode is on).
        let noncePhone = Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) })
        let startBody = try JSONEncoder().encode(
            PairStart(protocolVersion: 1, deviceName: "Chris's Pixel", noncePhone: noncePhone.base64EncodedString())
        )
        let started = try await client.request(port: port, path: "/v1/pair/start", method: "POST", body: startBody)
        #expect(started.status == 200)
        let startResponse = try JSONDecoder().decode(PairStartResponse.self, from: started.body)

        // Step 2: the phone computes the code and proof exactly as the Mac does.
        let nonceMac = try #require(Data(base64Encoded: startResponse.nonceMac))
        let code = PairingCode.code(
            fpMac: serverFingerprint,
            fpPhone: clientFingerprint,
            noncePhone: noncePhone,
            nonceMac: nonceMac
        )
        let proof = PairingCode.proof(code: code, sessionId: startResponse.sessionId)

        // Step 3: /v1/pair/confirm.
        let confirmBody = try JSONEncoder().encode(
            PairConfirm(sessionId: startResponse.sessionId, proof: proof)
        )
        let confirmed = try await client.request(port: port, path: "/v1/pair/confirm", method: "POST", body: confirmBody)
        #expect(confirmed.status == 200)
        let confirmResponse = try JSONDecoder().decode(PairConfirmResponse.self, from: confirmed.body)
        #expect(confirmResponse.status == "paired")
        #expect(confirmResponse.serverId == "server-xyz")

        // The device is now trusted and pairing mode has ended.
        #expect(trusted.fingerprints.contains(clientFingerprint))
        #expect(coordinator.pairingMode.isOn == false)

        // Step 4: a fresh connection, off pairing mode, is admitted because the
        // client is now trusted.
        let ping = try await client.request(port: port, path: "/v1/ping")
        #expect(ping.status == 200)

        // Step 5: revoking blocks the device at the TLS layer on the next connect.
        try await trusted.revoke(fingerprint: clientFingerprint)
        await #expect(throws: (any Error).self) {
            _ = try await client.request(port: port, path: "/v1/ping")
        }
    }
}
