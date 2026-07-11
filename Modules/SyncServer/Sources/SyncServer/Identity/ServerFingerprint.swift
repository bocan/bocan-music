import Crypto
import Foundation

/// The lowercase-hex SHA-256 of a certificate's DER encoding (64 chars). This is
/// the whole trust decision in Phone Sync: it goes in the Bonjour TXT record and
/// is pinned by the phone (see sync-protocol.md sections 2 and 3).
public struct ServerFingerprint: Sendable, Hashable {
    public let hex: String

    public init(hex: String) {
        self.hex = hex
    }

    /// Computes the fingerprint of a DER-encoded certificate.
    public init(certificateDER der: Data) {
        let digest = SHA256.hash(data: der)
        self.hex = digest.map { String(format: "%02x", $0) }.joined()
    }
}
