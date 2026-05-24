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

    // MARK: - Queue (Phase 5)

    case upNext

    // MARK: - Phase 6+

    /// A manual playlist.
    case playlist(Int64)

    /// A playlist folder (drills in to show children, not a track list).
    case folder(Int64)

    // MARK: - Phase 7+

    /// Stub — populated by Phase 7.
    case smartPlaylist(Int64)

    // MARK: - Phase 19 (Subsonic)

    //
    // Per-server browse roots. The associated `UUID` is the
    // `SubsonicServer.id`. Content views land in Phase 19 step 10; step 9
    // only adds the cases so the sidebar can tag rows.

    case subsonicSongs(UUID)
    case subsonicAlbums(UUID)
    case subsonicArtists(UUID)
    case subsonicGenres(UUID)

    // Optional per-server rows (Phase 19 step 11). The capability-gated
    // ones (Podcasts / Internet Radio / Bookmarks) are only registered in
    // the sidebar when the server's capability flags allow.

    case subsonicPlaylists(UUID)
    case subsonicPlaylist(UUID, String)
    case subsonicStarred(UUID)
    case subsonicRandom(UUID)
    case subsonicRecentlyAdded(UUID)
    case subsonicMostPlayed(UUID)
    case subsonicInternetRadio(UUID)
    case subsonicPodcasts(UUID)
    case subsonicBookmarks(UUID)

    // MARK: - Search

    case search(String)
}

/// Phase 19 step 17 helpers — Subsonic-server projection for routing.
public extension SidebarDestination {
    /// The Subsonic server ID this destination targets, if any. Used by
    /// `ContentPane` (Phase 19 step 17) to surface a per-server offline
    /// banner above the destination content.
    var subsonicServerID: UUID? {
        switch self {
        case let .subsonicSongs(id),
             let .subsonicAlbums(id),
             let .subsonicArtists(id),
             let .subsonicGenres(id),
             let .subsonicPlaylists(id),
             let .subsonicPlaylist(id, _),
             let .subsonicStarred(id),
             let .subsonicRandom(id),
             let .subsonicRecentlyAdded(id),
             let .subsonicMostPlayed(id),
             let .subsonicInternetRadio(id),
             let .subsonicPodcasts(id),
             let .subsonicBookmarks(id):
            id

        default:
            nil
        }
    }
}
