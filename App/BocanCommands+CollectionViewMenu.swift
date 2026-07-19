import SwiftUI
import UI

// MARK: - Collection view-mode menu helpers

extension BocanCommands {
    /// True when the active destination is one of the three collection listings
    /// (Artists, Genres, Composers), which are the only ones with a List/Grid
    /// view mode. The "View as" items are disabled elsewhere.
    var isCollectionListing: Bool {
        switch self.vm.selectedDestination {
        case .artists, .genres, .composers:
            true

        default:
            false
        }
    }

    /// Routes the View-menu List / Grid choice to the active section's
    /// `@AppStorage` key, so the visible listing updates live and persists. Reads
    /// `selectedDestination` when the menu acts rather than observing it (the VM
    /// is a plain `let` to keep the menu bar off the high-frequency render path).
    var collectionViewModeBinding: Binding<CollectionViewMode> {
        Binding(
            get: {
                switch self.vm.selectedDestination {
                case .genres:
                    self.genresViewMode

                case .composers:
                    self.composersViewMode

                default:
                    self.artistsViewMode
                }
            },
            set: { newValue in
                switch self.vm.selectedDestination {
                case .genres:
                    self.genresViewMode = newValue

                case .composers:
                    self.composersViewMode = newValue

                default:
                    self.artistsViewMode = newValue
                }
            }
        )
    }
}
