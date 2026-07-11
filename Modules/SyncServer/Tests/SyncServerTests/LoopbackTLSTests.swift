import Foundation
import os
import Security
import Testing
@testable import SyncServer

@Suite("Loopback TLS")
struct LoopbackTLSTests {
    @Test("ping, admission by pairing mode and trust, and off-main handling")
    func loopback() async throws {
        let serverStore = KeychainIdentityStore(service: "io.cloudcauldron.bocan.sync.test.server.\(UUID().uuidString)")
        let clientStore = KeychainIdentityStore(service: "io.cloudcauldron.bocan.sync.test.client.\(UUID().uuidString)")
        defer {
            serverStore.deleteAll()
            clientStore.deleteAll()
        }

        let serverIdentity = ServerIdentity(store: serverStore)
        let clientMaterial = try clientStore.loadOrCreate()
        let clientIdentity = try clientStore.secIdentity(for: clientMaterial)
        let clientFingerprint = ServerFingerprint(certificateDER: clientMaterial.certificateDER).hex

        let trusted = TrustedFingerprintSet()
        let pairing = OSAllocatedUnfairLock(initialState: true)
        let handlerRanOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)

        let router = Router(routes: [
            SyncRoutes.ping(serverId: { "server-123" }, generation: { 7 }),
            Router.Route("GET", "/test/thread", auth: .anyTLS) { _, _ in
                handlerRanOnMain.withLock { $0 = Thread.isMainThread }
                return HttpResponse(status: 200)
            },
        ])

        let listener = SyncListener(
            identity: serverIdentity,
            router: router,
            trusted: trusted,
            pairingMode: { pairing.withLock { $0 } }
        )
        let port = try await listener.start()
        defer { Task { await listener.stop() } }

        let client = LoopbackClient(clientIdentity: clientIdentity)

        // 1. Pairing mode: any client cert is admitted; ping returns the payload.
        let first = try await client.request(port: port, path: "/v1/ping")
        #expect(first.status == 200)
        let body = String(data: first.body, encoding: .utf8) ?? ""
        #expect(body.contains("\"serverId\":\"server-123\""))
        #expect(body.contains("\"generation\":7"))

        // 2. Out of pairing mode, an untrusted client is refused at the TLS layer.
        pairing.withLock { $0 = false }
        await #expect(throws: (any Error).self) {
            _ = try await client.request(port: port, path: "/v1/ping")
        }

        // 3. Trusting the client's fingerprint admits it again.
        trusted.replace(with: [clientFingerprint])
        let third = try await client.request(port: port, path: "/v1/ping")
        #expect(third.status == 200)

        // 4. Request handlers run off the MainActor.
        let fourth = try await client.request(port: port, path: "/test/thread")
        #expect(fourth.status == 200)
        #expect(handlerRanOnMain.withLock { $0 } == false)
    }
}
