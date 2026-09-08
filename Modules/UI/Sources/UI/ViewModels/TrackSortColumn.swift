import Foundation

// MARK: - TrackSortColumn

/// Codable column identifier used to persist table sort state.
///
/// `KeyPathComparator<Track>` is not `Codable`, so we store this enum
/// and reconstruct the comparator on load. See gotchas in ADR-005.
public enum TrackSortColumn: String, Codable, Sendable, CaseIterable {
    case title
    case artist
    case album
    case year
    case genre
    case duration
    case playCount
    case rating
    case addedAt
    case trackNumber
    case trackTotal
    case databaseID

    public var displayName: String {
        switch self {
        case .title:
            L10n.string("Title")

        case .artist:
            L10n.string("Artist")

        case .album:
            L10n.string("Album")

        case .year:
            L10n.string("Year")

        case .genre:
            L10n.string("Genre")

        case .duration:
            L10n.string("Time")

        case .playCount:
            L10n.string("Plays")

        case .rating:
            L10n.string("Rating")

        case .addedAt:
            L10n.string("Date Added")

        case .trackNumber:
            L10n.string("Track")

        case .trackTotal:
            L10n.string("Of")

        case .databaseID:
            L10n.string("ID")
        }
    }
}
