import SwiftUI

// MARK: - ContentPane

/// Switches the main content area based on the active `SidebarDestination`.
///
/// Passed a `LibraryViewModel` from the environment; uses child VMs for each
/// view.  Search results bypass the normal routing when a query is active.
public struct ContentPane: View {
    @ObservedObject public var vm: LibraryViewModel

    public init(vm: LibraryViewModel) {
        self.vm = vm
    }

    public var body: some View {
        Group {
            // If there is an active search query, show search results
            if !self.vm.search.query.isEmpty {
                SearchResultsView(vm: self.vm.search, library: self.vm)
            } else {
                self.destinationContent
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

        case let .genre(g):
            TracksView(vm: self.vm.tracks, library: self.vm, title: g)

        case let .composer(c):
            TracksView(vm: self.vm.tracks, library: self.vm, title: c)

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

        case let .search(q):
            SearchResultsView(vm: self.vm.search, library: self.vm)
                .onAppear {
                    self.vm.search.query = q
                    self.vm.search.queryChanged()
                }
        }
    }
}
