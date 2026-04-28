import Foundation

// MARK: - LyricsSourcePriority

/// The order in which ``LyricsService`` resolves competing lyrics sources.
///
/// Configure via ``LyricsSettingsView`` and stored in `UserDefaults`.
public enum LyricsSourcePriority: String, Sendable, CaseIterable, Codable {
    /// User-edited content wins; then embedded synced > sidecar > embedded unsynced > fetched.
    case preferEmbedded

    /// Sidecar `.lrc` files are preferred over embedded tags.
    case preferSynced

    /// The user's own edits are surfaced first, followed by the default order.
    case preferUser

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .preferEmbedded: "Prefer embedded tags"
        case .preferSynced: "Prefer synced (sidecar .lrc)"
        case .preferUser: "Prefer my edits"
        }
    }
}

// MARK: - LyricsSource

/// The concrete origin of a ``LyricsDocument``.
public enum LyricsSource: Sendable, Equatable {
    /// Written by the user via the editor (highest trust).
    case user
    /// Synced tags embedded in the audio file (SYLT / MP4).
    case embeddedSynced
    /// Sidecar `.lrc` file adjacent to the audio file.
    case sidecarLRC
    /// Unsynced tags embedded in the audio file (USLT / Vorbis LYRICS).
    case embeddedUnsynced
    /// Fetched from LRClib.net.
    case lrclib
}
