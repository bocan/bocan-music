import Foundation
import os

/// Per-connection state populated by the TLS verify block during the handshake
/// and read while handling requests. Thread-safe: the verify block runs on a
/// Network.framework queue while handlers run on the server's executor.
final class ConnectionContext: Sendable {
    private struct State {
        var peerCertificateDER: Data?
        var peerFingerprint: String?
        var isPairing = false
        var isTrusted = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// Records the peer certificate observed during the handshake and the
    /// admission decision. `isPairing` marks a pairing-mode connection;
    /// `isTrusted` marks a connection whose fingerprint is in `TrustedDevices`.
    func recordPeer(certificateDER: Data, fingerprint: String, isPairing: Bool, isTrusted: Bool) {
        self.state.withLock {
            $0.peerCertificateDER = certificateDER
            $0.peerFingerprint = fingerprint
            $0.isPairing = isPairing
            $0.isTrusted = isTrusted
        }
    }

    var peerCertificateDER: Data? {
        self.state.withLock { $0.peerCertificateDER }
    }

    var peerFingerprint: String? {
        self.state.withLock { $0.peerFingerprint }
    }

    var isPairing: Bool {
        self.state.withLock { $0.isPairing }
    }

    /// Whether this connection presented a trusted (paired) client certificate.
    var isTrusted: Bool {
        self.state.withLock { $0.isTrusted }
    }
}
