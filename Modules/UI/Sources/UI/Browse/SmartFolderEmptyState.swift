import SwiftUI

// MARK: - EmptyStateContent

/// What an empty list shows in place of the default empty-library state: a
/// symbol, a title and a message, with no action.
///
/// `TracksView` and `AlbumsGridView` assume an empty list means an empty
/// library and offer Add Music Folder. A smart folder is empty for another
/// reason, nothing in its window, so it passes its own content (#716).
public struct EmptyStateContent: Equatable, Sendable {
    let symbol: String
    let title: String
    let message: String

    /// The empty state for a smart folder, or nil for any other destination,
    /// which keeps the empty-library state. The symbols match the sidebar.
    /// Recently Added says the same in Songs and Albums mode: both list what
    /// was added in its window.
    static func smartFolder(_ destination: SidebarDestination) -> Self? {
        switch destination {
        case .recentlyAdded:
            Self(
                symbol: "clock",
                title: L10n.string("Nothing Added Recently"),
                message: L10n.string("No songs were added in the last \(RecentlyAddedView.windowDays) days.")
            )

        case .recentlyPlayed:
            Self(
                symbol: "clock.arrow.circlepath",
                title: L10n.string("Nothing Played Recently"),
                message: L10n.string("No songs were played in the last \(SmartFolderView.recentlyPlayedDays) days.")
            )

        case .mostPlayed:
            Self(
                symbol: "chart.bar",
                title: L10n.string("Nothing Played Yet"),
                message: L10n.string("The songs you play most will appear here.")
            )

        default:
            nil
        }
    }

    /// The view for this content: no action, because adding a music folder
    /// is not what an empty smart folder needs.
    var view: EmptyState {
        EmptyState(symbol: self.symbol, title: self.title, message: self.message)
    }
}
