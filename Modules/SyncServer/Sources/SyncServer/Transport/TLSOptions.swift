import Foundation
import Network
import Security

/// Builds the mutual-TLS options for the Phone Sync listener (sync-protocol.md
/// section 3): the server presents its identity, always requests a client
/// certificate, forces TLS 1.3, and runs a verify block that admits the
/// connection per the pairing-mode / trusted-device rule.
///
/// The verify block only makes the admission decision (which depends solely on
/// the peer fingerprint plus global state, so a single shared block is correct
/// for every connection). Per-connection peer state is recorded separately by
/// `HttpConnection`, which reads the negotiated peer certificate from the
/// connection's TLS metadata.
enum TLSOptions {
    static func make(
        identity: SecIdentity,
        pairingMode: @escaping @Sendable () -> Bool,
        isTrusted: @escaping @Sendable (String) -> Bool
    ) throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions

        guard let secIdentity = sec_identity_create(identity) else {
            throw SyncServerError.identity(reason: "secIdentityCreate", status: nil)
        }
        sec_protocol_options_set_local_identity(sec, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(sec, true)

        let verifyQueue = DispatchQueue(label: "io.cloudcauldron.bocan.sync.verify")
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            guard let leaf = Self.leafCertificate(from: trust) else {
                complete(false)
                return
            }
            let der = SecCertificateCopyData(leaf) as Data
            let fingerprint = ServerFingerprint(certificateDER: der).hex
            if pairingMode() {
                complete(true)
            } else {
                complete(isTrusted(fingerprint))
            }
        }, verifyQueue)

        return options
    }

    private static func leafCertificate(from trust: sec_trust_t) -> SecCertificate? {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate] else {
            return nil
        }
        return chain.first
    }
}
