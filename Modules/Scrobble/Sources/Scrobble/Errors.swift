import Foundation

// MARK: - ScrobbleError

/// Errors emitted by the Scrobble module.
public enum ScrobbleError: Error, Sendable, Equatable {
    /// The provider has no stored credentials (token, session key).
    case notAuthenticated(provider: String)
    /// The remote service rejected our credentials.
    case invalidCredentials(provider: String)
    /// The remote service returned a transient failure; the worker should retry.
    case transient(provider: String, reason: String, retryAfter: TimeInterval?)
    /// The remote service returned a permanent failure; mark the row dead.
    case permanent(provider: String, reason: String)
    /// Network is unreachable; pause submissions.
    case offline
    /// The local clock is too far skewed; backdated > 14 days.
    case timestampOutOfRange
    /// Keychain failed.
    case keychain(status: Int32, message: String)
    /// Unexpected response shape.
    case malformedResponse(provider: String, reason: String)
    /// Auth flow timed out (user did not authorise within the window).
    case authTimeout
    /// User cancelled the auth flow.
    case authCancelled
}

// MARK: - ScrobbleError + CustomStringConvertible

extension ScrobbleError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .notAuthenticated(provider):
            "\(provider): not signed in."
        case let .invalidCredentials(provider):
            "\(provider) rejected the saved credentials. Sign in again."
        case let .transient(provider, reason, _):
            "\(provider) is temporarily unavailable: \(reason). It will be retried."
        case let .permanent(provider, reason):
            "\(provider) rejected this play: \(reason)"
        case .offline:
            "No network connection. Plays are queued until it returns."
        case .timestampOutOfRange:
            "This play is too far in the past to submit."
        case let .keychain(status, message):
            "Keychain access failed: \(message) (status \(status))"
        case let .malformedResponse(provider, reason):
            "\(provider) returned an unexpected response: \(reason)"
        case .authTimeout:
            "The sign-in window closed before it was authorised."
        case .authCancelled:
            "Sign-in was cancelled."
        }
    }
}

// MARK: - ScrobbleError + LocalizedError

/// Without this, `localizedDescription` is Foundation's fallback. The Settings
/// panes put this straight into their error fields, so before #471 a failed
/// sign-in showed a raw case dump such as `notAuthenticated(provider: "lastfm")`.
extension ScrobbleError: LocalizedError {
    public var errorDescription: String? {
        self.description
    }
}
