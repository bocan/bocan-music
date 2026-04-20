import SwiftUI

// MARK: - ContentPane

/// Switches the main content area based on the active `SidebarDestination`.
///
/// Passed a `LibraryViewModel` from the environment; uses child VMs for each
/// view.  Search results bypass the normal routing when a query is active.
public struct ContentPane: View {
    @ObservedObject public var vm: LibraryViewModel
    /// Observed separately so the search-active branch reacts to query changes
    /// without depending on LibraryViewModel firing objectWillChange.
    @ObservedObject private var search: SearchViewModel

    public init(vm: LibraryViewModel) {
        self.vm = vm
        self.search = vm.search
    }

    public var body: some View {
        // Keep destinationContent permanently in the tree and overlay search results
        // on top when a query is active.  Replacing the detail column content
        // structurally causes macOS to disconnect the TextInputUIMacHelper ViewBridge,
        // killing focus on the toolbar search field after the first keystroke.
        self.destinationContent
            .overlay {
                if !self.search.query.isEmpty {
                    SearchResultsView(vm: self.search, library: self.vm)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch self.vm.selectedDestination {
        case .songs:
            TracksView(vm: self.vm.tracks, library: self.vm)

        case .albums:
            AlbumsGridView(vm: self.vm.albums, library: self.vm)

        case .artists:
            ArtistsView(vm: self.vm.artists, library: self.vm)

        case .genres:
            GenresView(library: self.vm)

        case .composers:
            ComposersView(library: self.vm)

        case .recentlyAdded, .recentlyPlayed, .mostPlayed:
            SmartFolderView(vm: self.vm.tracks, library: self.vm, destination: self.vm.selectedDestination)

        case let .artist(id):
            ArtistDetailView(artistID: id, library: self.vm)

        case let .album(id):
            AlbumDetailView(albumID: id, library: self.vm)

        case let .genre(genre):
            TracksView(vm: self.vm.tracks, library: self.vm, title: genre)

        case let .composer(c):
            TracksView(vm: self.vm.tracks, library: self.vm, title: c)

        case .upNext:
            QueueView(vm: self.vm)

        case .playlist:
            EmptyState(
                symbol: "music.note.list",
                title: "No Playlist",
                message: "Playlist support arrives in Phase 6."
            )

        case .smartPlaylist:
            EmptyState(
                symbol: "sparkles",
                title: "No Smart Playlist",
                message: "Smart Playlists arrive in Phase 7."
            )

        case let .search(searchQuery):
            // Search is shown via overlay above destinationContent; this case just
            // ensures the background destination is sensible.
            TracksView(vm: self.vm.tracks, library: self.vm)
                .task {
                    self.vm.search.query = searchQuery
                    self.vm.search.queryChanged()
                }
        }
    }
}
