import Foundation

// MARK: - JellyfinConnectionStatus

/// Live connection status for a single Jellyfin server.
///
/// The same six cases as the Subsonic status (ADR-097). The App maps this to
/// the UI's existing connection-state type.
public enum JellyfinConnectionStatus: Sendable, Equatable {
    /// Status not yet determined (app just launched, monitor not yet started).
    case unknown
    /// A ping is currently in flight.
    case connecting
    /// The last ping succeeded. `lastPing` is the wall-clock time of that ping.
    case online(lastPing: Date)
    /// The server rejected the access token (HTTP 401).
    /// The monitor stops retrying; the user must sign in again.
    case authFailed(String)
    /// The server could not be reached (DNS, network, TLS, timeout).
    case unreachable(String)
    /// The server returned a 5xx or an unexpected answer.
    case serverError(String)

    // MARK: - Derived helpers

    /// `true` if the server is currently reachable and authenticated.
    public var isOnline: Bool {
        if case .online = self {
            return true
        }
        return false
    }

    /// `true` if the failure lasts until the user intervenes.
    public var requiresUserAction: Bool {
        if case .authFailed = self {
            return true
        }
        return false
    }

    /// Human-readable description suitable for an accessibility label or tooltip.
    public var localizedDescription: String {
        switch self {
        case .unknown:
            return "Not yet connected"

        case .connecting:
            return "Connecting\u{2026}"

        case let .online(ping):
            let ago = RelativeDateTimeFormatter().localizedString(for: ping, relativeTo: Date())
            return "Online (last ping \(ago))"

        case let .authFailed(message):
            return "Authentication failed: \(message)"

        case let .unreachable(message):
            return "Unreachable: \(message)"

        case let .serverError(message):
            return "Server error: \(message)"
        }
    }
}
