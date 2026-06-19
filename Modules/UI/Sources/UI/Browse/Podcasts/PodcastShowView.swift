import SwiftUI

// MARK: - PodcastShowView

/// Placeholder episode list for a subscribed show. Phase 21-9 fills this in with
/// the episode table, duration/date columns, and progress indicators.
public struct PodcastShowView: View {
    @ObservedObject public var vm: PodcastsViewModel
    public var library: LibraryViewModel
    public var podcastID: Int64

    public init(vm: PodcastsViewModel, library: LibraryViewModel, podcastID: Int64) {
        self.vm = vm
        self.library = library
        self.podcastID = podcastID
    }

    public var body: some View {
        ContentUnavailableView(
            self.vm.currentShow?.title ?? L10n.string("Podcast"),
            systemImage: "antenna.radiowaves.left.and.right",
            description: Text(localized: "Episode list coming in phase 21-9.")
        )
        .task { await self.vm.loadShow(self.podcastID) }
        .navigationTitle(self.vm.currentShow?.title ?? L10n.string("Podcast"))
    }
}
