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

    /// Checkmark binding for one mode of the View-menu "View as" pair.
    /// Radio semantics: switching a mode on routes through
    /// `collectionViewModeBinding`; clicking the already-active mode is a
    /// no-op rather than unchecking it.
    func viewModeIsOn(_ mode: CollectionViewMode) -> Binding<Bool> {
        Binding(
            get: { self.collectionViewModeBinding.wrappedValue == mode },
            set: { isOn in
                if isOn { self.collectionViewModeBinding.wrappedValue = mode }
            }
        )
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
