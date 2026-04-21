import Foundation

/// The role a `playlists` row plays in the UI.
///
/// Persisted as a lowercase string in the `kind` column added by M007.
/// - `manual`: ordinary user-curated playlist backed by `playlist_tracks`.
/// - `smart`: rule-based playlist (Phase 7); membership is derived.
/// - `folder`: container that organises other playlists/folders via
///   `parent_id`. Folders have no tracks.
public enum PlaylistKind: String, Codable, Sendable, CaseIterable, Hashable {
    case manual
    case smart
    case folder
}
