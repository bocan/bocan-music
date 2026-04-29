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
