import Foundation
import Security

// MARK: - JellyfinError

/// Every error the `Jellyfin` module throws, so callers never see an SDK type.
///
/// The messages never carry a URL, a token or a password. A request URL can
/// hold the access token as `ApiKey`, so none is ever put in an error.
public enum JellyfinError: Error, Sendable, Equatable {
    /// The request did not reach a server answer (DNS, network, TLS, timeout).
    case network(String)
    /// The server answered with an HTTP error status.
    case http(status: Int)
    /// The server rejected the credentials or the access token (HTTP 401).
    case unauthorized
    /// The server's answer could not be read.
    case decoding(String)
    /// A Keychain operation failed; the `OSStatus` and the operation name are attached.
    case keychain(OSStatus, String)
    /// The stored server record is internally inconsistent.
    case invalidServerRecord(String)
    /// An operation was attempted on an unknown server ID.
    case unknownServer(UUID)
    /// The server answered, but not with a usable access token.
    case noAccessToken
    /// Quick Connect is switched off on the server.
    case quickConnectDisabled
    /// Nobody approved the Quick Connect code before it ran out.
    case quickConnectTimedOut
    /// The server URL is not usable (no host, or not http or https).
    case invalidServerURL(String)
    /// A stream or image URL could not be built.
    case invalidURL(String)

    // MARK: - Derived helpers

    /// `true` if the error is transient and the caller may retry.
    public var isTransient: Bool {
        switch self {
        case .network:
            true

        case let .http(status):
            status >= 500 || status == 408 || status == 429

        default:
            false
        }
    }

    /// `true` if the error means the Keychain item genuinely does not exist
    /// (as opposed to a transient read failure where the token is still stored
    /// but momentarily unreadable).
    public var isCredentialMissing: Bool {
        if case let .keychain(status, _) = self {
            return status == errSecItemNotFound
        }
        return false
    }

    /// `true` if the error indicates an authentication failure.
    public var isAuthenticationFailure: Bool {
        switch self {
        case .unauthorized:
            true

        case let .http(status):
            status == 401

        default:
            false
        }
    }
}

// MARK: - JellyfinError + LocalizedError

extension JellyfinError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .network(message):
            "Network error: \(message)"

        case let .http(status):
            "Server error (HTTP \(status))"

        case .unauthorized:
            "The server rejected the sign-in"

        case let .decoding(message):
            "Unreadable answer: \(message)"

        case let .keychain(status, operation):
            "Keychain \(operation) failed (OSStatus \(status))"

        case let .invalidServerRecord(message):
            "Invalid server record: \(message)"

        case let .unknownServer(id):
            "No server with id \(id)"

        case .noAccessToken:
            "The server did not return an access token"

        case .quickConnectDisabled:
            "Quick Connect is off on this server"

        case .quickConnectTimedOut:
            "The Quick Connect code was not approved in time"

        case let .invalidServerURL(message):
            "Invalid server URL: \(message)"

        case let .invalidURL(message):
            "Could not build a URL: \(message)"
        }
    }
}
