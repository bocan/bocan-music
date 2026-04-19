import Foundation

/// All possible navigation destinations in the sidebar.
///
/// Persisted to `settings` as part of `UIStateV1`, so the enum is `Codable`.
/// New cases must bump the `ui.state.v1` key version or add a migration.
public enum SidebarDestination: Hashable, Sendable, Codable {
    // MARK: - Library

    case songs
    case albums
    case artists
    case genres
    case composers

    // MARK: - Smart folders

    case recentlyAdded
    case recentlyPlayed
    case mostPlayed

    // MARK: - Drill-down

    case artist(Int64)
    case album(Int64)
    case genre(String)
    case composer(String)

    // MARK: - Phase 6+

    /// Stub — populated by Phase 6.
    case playlist(Int64)

    // MARK: - Phase 7+

    /// Stub — populated by Phase 7.
    case smartPlaylist(Int64)

    // MARK: - Search

    case search(String)
}
