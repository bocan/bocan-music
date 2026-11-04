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

// MARK: - ScrobbleError + one-shot requests

extension ScrobbleError {
    /// The cause of the failure, without the scrobble queue's next step.
    ///
    /// `description` speaks for the queue: a transient failure "will be
    /// retried" and an offline play waits for the network. A love and a
    /// now-playing update are sent once and never queued, so a log line that
    /// used `description` for them promised a retry that never came (#677).
    var causeDescription: String {
        switch self {
        case let .transient(provider, reason, _):
            "\(provider) is temporarily unavailable: \(reason)."

        case let .permanent(provider, reason):
            "\(provider) rejected the request: \(reason)"

        case .offline:
            "No network connection."

        default:
            self.description
        }
    }

    /// `causeDescription` for a `ScrobbleError`, the full reflection for any
    /// other error (a `URLError`, a decoding error), which says nothing about
    /// retries.
    static func causeDescription(of error: any Error) -> String {
        (error as? ScrobbleError)?.causeDescription ?? String(reflecting: error)
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
