import SwiftUI

// MARK: - ArtistScopeMenu

/// A toolbar dropdown choosing which artists populate the Artists list (#369).
///
/// Unlike ``SortMenu`` this is a filter, so it follows the platform's filter
/// affordance: the funnel icon swaps to its filled variant whenever a narrowing
/// scope is active. The preference persists across launches, and a filled
/// funnel is the only always-visible hint that the list is showing a subset,
/// so the icon swap is load-bearing, not decoration.
struct ArtistScopeMenu: View {
    @Binding var selection: ArtistScope

    var body: some View {
        Menu {
            Picker(L10n.string("Show"), selection: self.$selection) {
                ForEach(ArtistScope.allCases, id: \.self) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(
                L10n.string("Filter"),
                systemImage: self.selection == .albumArtists
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .help(L10n.string("Choose which artists are shown"))
    }
}
