import SwiftUI

// MARK: - PodcastAddBar

/// The always-present search/add bar at the top of the Podcasts window.
///
/// Owns the text binding; search results and the add-by-URL flow are filled in
/// by phase 21-8 via a popover attached to this bar.
struct PodcastAddBar: View {
    @ObservedObject var vm: PodcastsViewModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textSecondary)
                .accessibilityHidden(true)

            TextField(
                L10n.string("Search podcasts or paste a feed URL"),
                text: self.$vm.addBarText
            )
            .textFieldStyle(.plain)
            .accessibilityLabel(L10n.string("Search podcasts or paste a feed URL"))

            if !self.vm.addBarText.isEmpty {
                Button {
                    self.vm.addBarText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Clear search"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
