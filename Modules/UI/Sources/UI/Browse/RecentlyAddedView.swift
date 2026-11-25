import SwiftUI

// MARK: - RecentlyAddedView

/// The Recently Added destination: the songs added in the last 30 days as a
/// track list (Songs, the default and the historical behaviour), or the albums
/// they belong to as a grid, newest addition first (#700).
///
/// The same Songs / Albums switch as a genre or composer (ADR-074), persisted
/// by the caller under `recentlyAdded.detailMode`. The switch sits outside the
/// `if`, so it survives the toolbar's overflow menu (docs/GOTCHAS.md). Albums
/// mode uses a locally owned `AlbumsViewModel` with its own sort key, so it
/// never changes the main Albums grid's contents or its sort.
struct RecentlyAddedView: View {
    /// The window both modes share, in days.
    static let windowDays = 30

    @Binding var mode: CollectionDetailMode
    var library: LibraryViewModel

    @StateObject private var albumsVM: AlbumsViewModel

    init(mode: Binding<CollectionDetailMode>, library: LibraryViewModel) {
        self._mode = mode
        self.library = library
        self._albumsVM = StateObject(wrappedValue: AlbumsViewModel(
            repository: library.albumRepo,
            sortOrderKey: AlbumsViewModel.recentlyAddedSortOrderKey,
            defaultSortOrder: .dateAdded
        ))
    }

    var body: some View {
        Group {
            if self.mode == .albums {
                AlbumsGridView(
                    vm: self.albumsVM,
                    library: self.library,
                    title: L10n.string("Recently Added"),
                    emptyState: EmptyStateContent.smartFolder(.recentlyAdded)
                )
                // Only while Albums mode is on, so Songs mode never fetches albums.
                .task { await self.albumsVM.load(addedWithinDays: Self.windowDays) }
            } else {
                SmartFolderView(vm: self.library.tracks, library: self.library, destination: .recentlyAdded)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CollectionDetailModeToggle(mode: self.$mode)
            }
        }
    }
}
