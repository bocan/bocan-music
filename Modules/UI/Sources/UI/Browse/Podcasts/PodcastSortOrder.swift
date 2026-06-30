import Foundation

// MARK: - PodcastSortOrder

/// Sort order for the subscribed-shows grid in `PodcastsHomeView`.
public enum PodcastSortOrder: String, CaseIterable, Sendable, SortMenuOption {
    /// Podcast title, A->Z (the default).
    case podcastName
    /// Unplayed-episode count, most first, then podcast title.
    case unplayedCount
    /// Total-episode count, most first, then podcast title.
    case totalEpisodes

    /// Localized label shown in the grid's sort menu.
    public var displayName: String {
        switch self {
        case .podcastName:
            L10n.string("Podcast Name")

        case .unplayedCount:
            L10n.string("Unplayed Episode Count")

        case .totalEpisodes:
            L10n.string("Total Episodes")
        }
    }
}
