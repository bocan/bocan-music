import Crypto
import Foundation
import Security
import Testing
import X509
@testable import SyncServer

@Suite("SelfSignedCert")
struct SelfSignedCertTests {
    @Test("generate produces a DER the Security framework accepts as a certificate")
    func derIsAValidCertificate() throws {
        let material = try SelfSignedCert.generate()
        let cert = SecCertificateCreateWithData(nil, material.certificateDER as CFData)
        #expect(cert != nil)
    }

    @Test("common name is bocan-mac-<8 hex>")
    func commonNameFormat() throws {
        let material = try SelfSignedCert.generate()
        #expect(material.commonName.hasPrefix("bocan-mac-"))
        let suffix = material.commonName.dropFirst("bocan-mac-".count)
        // Hoisted out of #expect: the keypath form trips the macro expansion.
        let suffixIsHex = suffix.allSatisfy(\.isHexDigit)
        #expect(suffix.count == 8)
        #expect(suffixIsHex)
    }

    @Test("fingerprint is 64 lowercase hex characters")
    func fingerprintFormat() throws {
        let material = try SelfSignedCert.generate()
        let fingerprint = ServerFingerprint(certificateDER: material.certificateDER)
        #expect(fingerprint.hex.count == 64)
        #expect(fingerprint.hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("validity is 25 years and the certificate is self-signed")
    func validityAndSubject() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let material = try SelfSignedCert.generate(now: now)
        let cert = try Certificate(derEncoded: Array(material.certificateDER))

        let years = cert.notValidAfter.timeIntervalSince(cert.notValidBefore) / (365.25 * 24 * 60 * 60)
        #expect(abs(years - 25) < 0.01)
        #expect(cert.issuer == cert.subject) // self-signed
    }

    @Test("the stored private key matches the certificate's public key")
    func keyMatchesCertificate() throws {
        let material = try SelfSignedCert.generate()
        let cert = try Certificate(derEncoded: Array(material.certificateDER))
        let key = try P256.Signing.PrivateKey(x963Representation: material.privateKeyX963)
        #expect(cert.publicKey == Certificate.PublicKey(key.publicKey))
    }

    @Test("each generation yields a distinct identity")
    func generationsAreDistinct() throws {
        let a = try SelfSignedCert.generate()
        let b = try SelfSignedCert.generate()
        #expect(a.certificateDER != b.certificateDER)
        #expect(a.commonName != b.commonName || a.privateKeyX963 != b.privateKeyX963)
    }
}
