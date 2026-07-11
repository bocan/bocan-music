import Foundation
import os
import Security
import Testing
@testable import SyncServer

/// A URLSession delegate that presents a client certificate and trusts the
/// self-signed loopback server. Test-only.
private final class LoopbackClientDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let clientIdentity: SecIdentity

    init(clientIdentity: SecIdentity) {
        self.clientIdentity = clientIdentity
    }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            let credential = URLCredential(
                identity: self.clientIdentity,
                certificates: nil,
                persistence: .forSession
            )
            completionHandler(.useCredential, credential)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

@Suite("Loopback TLS")
struct LoopbackTLSTests {
    /// Issues a GET over a fresh session (fresh TLS handshake, no keep-alive
    /// reuse) and returns the status and body.
    private func get(
        port: UInt16,
        path: String,
        clientIdentity: SecIdentity
    ) async throws -> (status: Int, body: Data) {
        let delegate = LoopbackClientDelegate(clientIdentity: clientIdentity)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

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

        // 1. Pairing mode: any client cert is admitted; ping returns the payload.
        let first = try await self.get(port: port, path: "/v1/ping", clientIdentity: clientIdentity)
        #expect(first.status == 200)
        let body = String(data: first.body, encoding: .utf8) ?? ""
        #expect(body.contains("\"serverId\":\"server-123\""))
        #expect(body.contains("\"generation\":7"))

        // 2. Out of pairing mode, an untrusted client is refused at the TLS layer.
        pairing.withLock { $0 = false }
        await #expect(throws: (any Error).self) {
            _ = try await self.get(port: port, path: "/v1/ping", clientIdentity: clientIdentity)
        }

        // 3. Trusting the client's fingerprint admits it again.
        trusted.replace(with: [clientFingerprint])
        let third = try await self.get(port: port, path: "/v1/ping", clientIdentity: clientIdentity)
        #expect(third.status == 200)

        // 4. Request handlers run off the MainActor.
        let fourth = try await self.get(port: port, path: "/test/thread", clientIdentity: clientIdentity)
        #expect(fourth.status == 200)
        #expect(handlerRanOnMain.withLock { $0 } == false)
    }
}
