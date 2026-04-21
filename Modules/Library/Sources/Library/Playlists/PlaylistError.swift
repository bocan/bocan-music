import Foundation

/// Errors thrown by `PlaylistService`.
public enum PlaylistError: Error, Sendable, CustomStringConvertible, Equatable {
    /// The requested playlist does not exist (or was already deleted).
    case notFound(Int64)

    /// Attempted to modify a folder as if it were a playlist (or vice versa).
    case wrongKind(id: Int64, expected: String, actual: String)

    /// Attempted to move a folder into itself or one of its descendants.
    case cycleDetected(id: Int64, newParent: Int64)

    /// Playlist name was empty after trimming whitespace.
    case emptyName

    /// Accent colour string is not a `"#RRGGBB"` hex value.
    case invalidAccentColor(String)

    public var description: String {
        switch self {
        case let .notFound(id):
            "Playlist \(id) not found"
        case let .wrongKind(id, expected, actual):
            "Playlist \(id) is a \(actual); expected a \(expected)"
        case let .cycleDetected(id, newParent):
            "Moving \(id) under \(newParent) would create a cycle"
        case .emptyName:
            "Playlist name cannot be empty"
        case let .invalidAccentColor(hex):
            "Accent colour '\(hex)' is not a #RRGGBB hex string"
        }
    }
}
