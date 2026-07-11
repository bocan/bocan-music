import CryptoKit
import Foundation

/// Derivation of the six-digit pairing verification code and the confirm proof,
/// exactly per `sync-protocol.md` section 4. The math is shared byte-for-byte
/// with the Android client; the golden vectors in `PairingCodeTests` (copied
/// byte-identical from the Android repo) are the contract that keeps the two
/// implementations in agreement.
///
/// The code is a *verification* code, not a secret: it is derived from both
/// certificate fingerprints and both nonces, so a man-in-the-middle that
/// terminates TLS on one side holds a different certificate pair, computes a
/// different code, and the code the user copies from the Mac fails on the phone.
/// Matching is the proof; there is no secret entropy to brute force.
public enum PairingCode {
    /// ASCII literal mixed into the code derivation (protocol section 4).
    private static let label = "bocan-pair-v1"

    /// The six-digit verification code, zero-padded (for example `"704898"`).
    ///
    /// - Parameters:
    ///   - fpMac: lowercase hex SHA-256 of the Mac certificate DER (64 chars).
    ///   - fpPhone: lowercase hex SHA-256 of the phone certificate DER (64 chars).
    ///   - noncePhone: the phone's 32 random bytes.
    ///   - nonceMac: the Mac's 32 random bytes.
    /// - Returns: the six-digit code as a zero-padded string.
    public static func code(
        fpMac: String,
        fpPhone: String,
        noncePhone: Data,
        nonceMac: Data
    ) -> String {
        // Order independent: both sides sort the fingerprints lexicographically,
        // so the ceremony yields the same code regardless of which peer is the
        // "Mac". For equal-length lowercase hex strings this ordering matches
        // byte order.
        let fpLo = min(fpMac, fpPhone)
        let fpHi = max(fpMac, fpPhone)

        // HMAC key = noncePhone || nonceMac (phone nonce first), raw bytes.
        var key = Data()
        key.append(noncePhone)
        key.append(nonceMac)

        // msg = "bocan-pair-v1" || fpLo || fpHi, ASCII bytes, no separators.
        var message = Data(Self.label.utf8)
        message.append(Data(fpLo.utf8))
        message.append(Data(fpHi.utf8))

        let mac = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: key)
        )

        // First 8 bytes as an unsigned big-endian UInt64, then mod 1_000_000.
        var value: UInt64 = 0
        for byte in Data(mac).prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return String(format: "%06d", value % 1_000_000)
    }

    /// The base64 confirm proof for a session id (protocol section 4 step 5):
    /// `HMAC-SHA256(key = code as ASCII bytes, msg = sessionId as ASCII bytes)`.
    ///
    /// - Parameters:
    ///   - code: the six-digit code string (the zero-padded output of `code(...)`).
    ///   - sessionId: the pairing session id (a UUID string).
    /// - Returns: the standard base64 encoding (with padding) of the HMAC output.
    public static func proof(code: String, sessionId: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(sessionId.utf8),
            using: SymmetricKey(data: Data(code.utf8))
        )
        return Data(mac).base64EncodedString()
    }
}
