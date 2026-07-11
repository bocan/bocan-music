import Crypto
import Foundation
import SwiftASN1
import X509

/// Generates the P-256 self-signed certificate that identifies this Mac to paired
/// phones. Per sync-protocol.md section 2: subject/issuer CN `bocan-mac-<8 hex>`,
/// 25-year validity, no renewal path (repairing is the recovery story). The
/// device fingerprint is the SHA-256 of the certificate DER.
enum SelfSignedCert {
    /// A freshly generated identity: the private key in X9.63 form (for Keychain
    /// import as a `SecKey`) plus the certificate DER and its common name.
    struct Material {
        let privateKeyX963: Data
        let certificateDER: Data
        let commonName: String
    }

    /// 25 years in seconds (validity per the protocol; there is no renewal path).
    private static let validityInterval: TimeInterval = 25 * 365.25 * 24 * 60 * 60

    /// Generates a new P-256 key and a self-signed certificate over it. Used by
    /// tests and the in-memory identity store; the Keychain store generates its
    /// key in the Keychain and calls `makeCertificate(for:now:)` directly.
    static func generate(now: Date = Date()) throws -> Material {
        let key = P256.Signing.PrivateKey()
        let certificate = try Self.makeCertificate(for: key, now: now)
        return Material(
            privateKeyX963: key.x963Representation,
            certificateDER: certificate.der,
            commonName: certificate.commonName
        )
    }

    /// Builds a self-signed certificate over an existing P-256 key and returns
    /// its DER encoding plus the generated common name.
    static func makeCertificate(
        for key: P256.Signing.PrivateKey,
        now: Date = Date()
    ) throws -> (der: Data, commonName: String) {
        let commonName = "bocan-mac-\(Self.randomHex(byteCount: 4))"

        let name = try DistinguishedName {
            CommonName(commonName)
        }

        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(bytes: Self.randomSerialBytes()),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: now,
            notValidAfter: now.addingTimeInterval(Self.validityInterval),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                KeyUsage(digitalSignature: true, keyCertSign: true)
            },
            issuerPrivateKey: Certificate.PrivateKey(key)
        )

        var serializer = DER.Serializer()
        try serializer.serialize(certificate)

        return (Data(serializer.serializedBytes), commonName)
    }

    /// A random, positive 20-byte serial number (high bit cleared so the DER
    /// INTEGER is non-negative).
    private static func randomSerialBytes() -> [UInt8] {
        var bytes = (0 ..< 20).map { _ in UInt8.random(in: .min ... .max) }
        bytes[0] &= 0x7F
        if bytes[0] == 0 { bytes[0] = 0x01 } // avoid a leading zero byte
        return bytes
    }

    private static func randomHex(byteCount: Int) -> String {
        (0 ..< byteCount)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }
            .joined()
    }
}
