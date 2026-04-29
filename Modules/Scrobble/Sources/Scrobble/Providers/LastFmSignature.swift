import CryptoKit
import Foundation

// MARK: - LastFmSignature

/// Builds the `api_sig` parameter required by every Last.fm authenticated method.
///
/// Per the spec at https://www.last.fm/api/desktopauth :
/// > Concatenate every parameter (excluding `format` and `callback`) into a
/// > single string in **alphabetical key order** as `key1value1key2value2…`,
/// > append the shared secret, then take the MD5 hex digest in lower-case.
///
/// This is a pure function so it can be exhaustively unit-tested against the
/// fixture in the Last.fm docs.
public enum LastFmSignature {
    /// Names that are **excluded** from the signature.
    public static let excludedKeys: Set = ["format", "callback"]

    /// Returns the lower-case hex MD5 digest for the given parameters and secret.
    public static func sign(_ parameters: [String: String], secret: String) -> String {
        let pairs = parameters
            .filter { !self.excludedKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)\($0.value)" }
            .joined()
        let toSign = pairs + secret
        let digest = Insecure.MD5.hash(data: Data(toSign.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
