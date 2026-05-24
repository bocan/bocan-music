import Foundation
import SwiftSonic

// MARK: - SubsonicError

/// Classifies errors from the `Subsonic` module so callers never need to
/// import `SwiftSonic` directly.
public enum SubsonicError: Error, Sendable {
    /// The underlying `SwiftSonicError` (network, HTTP, API, decode).
    case transport(SwiftSonicError)
    /// A Keychain operation failed; the `OSStatus` is attached.
    case keychain(OSStatus, String)
    /// The stored server record is internally inconsistent.
    case invalidServerRecord(String)
    /// An operation was attempted on an unknown server ID.
    case unknownServer(UUID)
    /// The server was reachable but returned an API error (wrapped for convenience).
    case apiError(code: Int, message: String)

    // MARK: - Derived helpers

    /// `true` if the error is transient and the caller may retry.
    public var isTransient: Bool {
        switch self {
        case let .transport(e): e.isTransient
        case .keychain: false
        case .invalidServerRecord: false
        case .unknownServer: false
        case .apiError: false
        }
    }

    /// `true` if the error indicates an authentication failure.
    public var isAuthenticationFailure: Bool {
        switch self {
        case let .transport(e): e.isAuthenticationFailure
        case let .apiError(code, _): code == 40 || code == 41
        default: false
        }
    }
}

// MARK: - SubsonicError + LocalizedError

extension SubsonicError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .transport(e): e.localizedDescription
        case let .keychain(status, op): "Keychain \(op) failed (OSStatus \(status))"
        case let .invalidServerRecord(msg): "Invalid server record: \(msg)"
        case let .unknownServer(id): "No server with id \(id)"
        case let .apiError(code, msg): "API error \(code): \(msg)"
        }
    }
}
