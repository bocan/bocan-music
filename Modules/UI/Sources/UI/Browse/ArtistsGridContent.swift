import SwiftUI

// MARK: - ArtistsGridContent

/// Grid mode for `ArtistsView`: renders each artist as a ``CollectionCard`` in a
/// ``CollectionCardGrid``. List mode remains the original code path in
/// `ArtistsView`; this file exists so `ArtistsView.swift` stays under the
/// 500-line ceiling (phase 23-1).
///
/// Card order follows `vm.artists`, so the shared `SortMenu` reorders the grid
/// live, identical to list mode. Opening a card snapshots `lastVisitedArtistID`
/// (matching the list-row path) so the grid re-centers on return.
struct ArtistsGridContent: View {
    @ObservedObject var vm: ArtistsViewModel
    var library: LibraryViewModel

    var body: some View {
        CollectionCardGrid(
            models: self.models,
            placeholderSymbol: "music.mic",
            cardAccessibilityHint: L10n.string("Opens this artist's albums and songs"),
            onOpen: { self.open($0) },
            contextMenu: { model in self.contextMenu(for: model) },
            scrollOffset: Binding(
                get: { self.vm.gridScrollOffset },
                set: { self.vm.gridScrollOffset = $0 }
            )
        )
    }

    /// Builds the card models from the already-sorted `vm.artists` plus the
    /// counts and cover-path maps loaded alongside them.
    private var models: [CollectionCardModel] {
        self.vm.artists.compactMap { artist in
            guard let id = artist.id else { return nil }
            return CollectionCardModel(
                id: String(id),
                title: artist.name,
                albumCount: self.vm.albumCounts[id] ?? 0,
                songCount: self.vm.trackCounts[id] ?? 0,
                coverArtPaths: self.vm.coverArtPaths[id] ?? []
            )
        }
    }

    private func open(_ idString: String) {
        guard let id = Int64(idString) else { return }
        // Snapshot the visited artist so the grid scrolls it back into view when
        // it's rebuilt on return, matching the list-row path (#360 wiring).
        self.vm.lastVisitedArtistID = id
        Task { await self.library.selectDestination(.artist(id)) }
    }

    @ViewBuilder
    private func contextMenu(for model: CollectionCardModel) -> some View {
        if let id = Int64(model.id) {
            Button(L10n.string("Remove Artist from Library"), role: .destructive) {
                Task {
                    await RemoveFromLibraryConfirm.artist(
                        id: id, name: model.title, library: self.library
                    )
                }
            }
        }
    }
}
