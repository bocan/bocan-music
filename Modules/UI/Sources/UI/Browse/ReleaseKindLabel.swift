import Foundation

// MARK: - ReleaseKindLabel

/// Display mapping for `albums.release_type` (MusicBrainz primary and secondary
/// type names, lowercased, owned by the Metadata / Persistence layers). Unknown
/// values fall back to the raw string with a capital so nothing is hidden.
enum ReleaseKindLabel {
    static func string(for releaseType: String) -> String {
        switch releaseType {
        case "album":
            L10n.string("Album")

        case "single":
            L10n.string("Single")

        case "ep":
            L10n.string("EP")

        case "broadcast":
            L10n.string("Broadcast")

        case "compilation":
            L10n.string("Compilation")

        case "live":
            L10n.string("Live")

        case "soundtrack":
            L10n.string("Soundtrack")

        case "remix":
            L10n.string("Remix")

        case "demo":
            L10n.string("Demo")

        case "mixtape/street":
            L10n.string("Mixtape")

        case "dj-mix":
            L10n.string("DJ Mix")

        case "audiobook":
            L10n.string("Audiobook")

        case "spokenword":
            L10n.string("Spoken Word")

        case "interview":
            L10n.string("Interview")

        case "audio drama":
            L10n.string("Audio Drama")

        case "other":
            L10n.string("Other")

        default:
            releaseType.capitalized
        }
    }
}
