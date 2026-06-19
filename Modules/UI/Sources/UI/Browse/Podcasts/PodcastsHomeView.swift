import SwiftUI

// MARK: - PodcastsHomeView

/// Main Podcasts window: a persistent Add bar docked at the top, followed by
/// either the search results list (when the user has typed) or the subscribed-
/// shows grid (or empty state) when the search is idle.
///
/// Routed from `ContentPane` for `.podcasts`.
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
                if self.vm.searchState == .idle {
                    if self.vm.subscribed.isEmpty {
                        PodcastsEmptyState()
                    } else {
                        PodcastsGridView(vm: self.vm, library: self.library)
                    }
                } else {
                    PodcastSearchResultsView(vm: self.vm)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(L10n.string("Podcasts"))
        // Debounce: task(id:) cancels the prior task when addBarText changes.
        // The 300 ms sleep is the debounce window; CancellationError means a new
        // character arrived -- do not call onAddBarTextChanged.
        .task(id: self.vm.addBarText) {
            do {
                try await Task.sleep(for: .milliseconds(300))
                await self.vm.onAddBarTextChanged(self.vm.addBarText)
            } catch {
                // CancellationError -- text changed within 300 ms; debounce working.
            }
        }
        .sheet(
            isPresented: self.$vm.showingDetail,
            onDismiss: { self.vm.dismissDetail() },
            content: {
                if let detail = self.vm.currentDetail {
                    PodcastDetailView(vm: self.vm, detail: detail)
                } else {
                    PodcastDetailLoadingView(vm: self.vm)
                }
            }
        )
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
