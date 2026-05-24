import Foundation

// MARK: - SubsonicConnectionStatus

/// Live connection status for a single remote server.
public enum SubsonicConnectionStatus: Sendable, Equatable {
    /// Status not yet determined (app just launched, monitor not yet started).
    case unknown
    /// A ping is currently in flight.
    case connecting
    /// The last ping succeeded. `lastPing` is the wall-clock time of that ping.
    case online(lastPing: Date)
    /// The server rejected credentials (HTTP 401 / API error code 40).
    /// The monitor stops retrying; the user must edit the server to recover.
    case authFailed(String)
    /// The server could not be reached (DNS, network, TLS, timeout).
    case unreachable(String)
    /// The server returned a 5xx or an unexpected API error.
    case serverError(String)

    // MARK: - Derived helpers

    /// `true` if the server is currently reachable and authenticated.
    public var isOnline: Bool {
        if case .online = self { return true }
        return false
    }

    /// `true` if the failure is permanent until the user intervenes.
    public var requiresUserAction: Bool {
        if case .authFailed = self { return true }
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
        case let .authFailed(msg):
            return "Authentication failed: \(msg)"
        case let .unreachable(msg):
            return "Unreachable: \(msg)"
        case let .serverError(msg):
            return "Server error: \(msg)"
        }
    }
}
