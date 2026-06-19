import CryptoKit
import Foundation

/// Computes the three authentication headers required by the Podcast Index API.
///
/// Every request signs `apiKey + apiSecret + unixSeconds` with SHA-1 and sends
/// the lowercase hex digest in the Authorization header. SHA-1 is mandated by the
/// API -- it is a request signature, not a security primitive. Do not upgrade it.
enum PodcastIndexAuth {
    /// Returns the three auth headers for a given request time.
    ///
    /// - X-Auth-Key: the API key
    /// - X-Auth-Date: current unix time as a decimal string
    /// - Authorization: SHA-1 hex of (apiKey + apiSecret + unixSeconds)
    ///
    /// Inject `now` to get deterministic output in tests.
    static func headers(credentials: PodcastIndexCredentials, now: Date) -> [String: String] {
        let unixSeconds = String(Int(now.timeIntervalSince1970))
        let input = credentials.apiKey + credentials.apiSecret + unixSeconds
        let digest = Insecure.SHA1.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return [
            "X-Auth-Key": credentials.apiKey,
            "X-Auth-Date": unixSeconds,
            "Authorization": hex,
        ]
    }
}
