import SwiftUI

// MARK: - PodcastsHomeView

/// Main Podcasts window: a persistent Add bar docked at the top and a subscribed-
/// shows grid (or empty state) below. Routed from `ContentPane` for `.podcasts`.
public struct PodcastsHomeView: View {
    @ObservedObject public var vm: PodcastsViewModel
    public var library: LibraryViewModel

    public init(vm: PodcastsViewModel, library: LibraryViewModel) {
        self.vm = vm
        self.library = library
    }

    public var body: some View {
        VStack(spacing: 0) {
            PodcastAddBar(vm: self.vm)
            Divider()
            Group {
                if self.vm.subscribed.isEmpty {
                    PodcastsEmptyState()
                } else {
                    PodcastsGridView(vm: self.vm, library: self.library)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(L10n.string("Podcasts"))
    }
}

// MARK: - PodcastsEmptyState

/// Shown when the user has no subscriptions yet.
private struct PodcastsEmptyState: View {
    var body: some View {
        EmptyState(
            symbol: "antenna.radiowaves.left.and.right",
            title: L10n.string("No Podcasts"),
            message: L10n.string("Subscribe to a podcast to get started.")
        )
    }
}
