import Foundation
import Network
import Security

/// Drives one accepted `NWConnection`: after the TLS handshake it records the
/// negotiated peer certificate into a `ConnectionContext`, then reads requests,
/// dispatches them through the `Router`, and writes responses. HTTP/1.1
/// keep-alive is supported; the connection closes on any parse error.
///
/// All request handling runs on this actor's executor, off the MainActor.
actor HttpConnection {
    private let connection: NWConnection
    private let context = ConnectionContext()
    private let router: Router
    private let pairingMode: @Sendable () -> Bool
    private let isTrusted: @Sendable (String) -> Bool
    private var parser = HttpRequestParser()

    init(
        connection: NWConnection,
        router: Router,
        pairingMode: @escaping @Sendable () -> Bool,
        isTrusted: @escaping @Sendable (String) -> Bool
    ) {
        self.connection = connection
        self.router = router
        self.pairingMode = pairingMode
        self.isTrusted = isTrusted
    }

    nonisolated func start(queue: DispatchQueue) {
        // The listener does not retain the handler, so the state handler holds a
        // strong reference to keep this actor alive for the connection's life;
        // reaching a terminal state clears the handler to break the cycle.
        self.connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Task { await self.onReady() }
            case .failed, .cancelled:
                self.connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        self.connection.start(queue: queue)
    }

    private func onReady() async {
        self.populateContext()
        await self.readLoop()
        self.connection.cancel()
    }

    /// Reads the peer certificate from the negotiated TLS metadata and records
    /// the admission decision for the router's authorization check.
    private func populateContext() {
        guard
            let metadata = self.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return
        }
        var leafDER: Data?
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            if leafDER == nil {
                let secCert = sec_certificate_copy_ref(certificate).takeRetainedValue()
                leafDER = SecCertificateCopyData(secCert) as Data
            }
        }
        guard let leafDER else { return }
        let fingerprint = ServerFingerprint(certificateDER: leafDER).hex
        self.context.recordPeer(
            certificateDER: leafDER,
            fingerprint: fingerprint,
            isPairing: self.pairingMode(),
            isTrusted: self.isTrusted(fingerprint)
        )
    }

    // MARK: - Read / dispatch loop

    private enum ReceiveResult {
        case chunk(Data)
        case final(Data)
        case end
    }

    private func readLoop() async {
        while true {
            switch await self.receiveChunk() {
            case let .chunk(data):
                if await self.ingest(data) { return }
            case let .final(data):
                _ = await self.ingest(data)
                return
            case .end:
                return
            }
        }
    }

    private func receiveChunk() async -> ReceiveResult {
        await withCheckedContinuation { continuation in
            self.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if error != nil {
                    continuation.resume(returning: .end)
                } else if isComplete {
                    continuation.resume(returning: .final(data ?? Data()))
                } else {
                    continuation.resume(returning: .chunk(data ?? Data()))
                }
            }
        }
    }

    /// Feeds bytes to the parser; dispatches a completed request and writes the
    /// response. Returns `true` when the connection should close.
    private func ingest(_ data: Data) async -> Bool {
        guard !data.isEmpty else { return false }
        switch self.parser.feed(data) {
        case .incomplete:
            return false
        case let .failure(response):
            await self.send(response)
            return true
        case let .request(request, leftover):
            let response = await self.router.dispatch(request, context: self.context)
            await self.send(response)
            self.parser = HttpRequestParser()
            if !leftover.isEmpty {
                return await self.ingest(leftover)
            }
            return false
        }
    }

    private func send(_ response: HttpResponse) async {
        let bytes = response.serialized()
        await withCheckedContinuation { continuation in
            self.connection.send(content: bytes, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}
