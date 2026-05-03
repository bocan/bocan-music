import SwiftUI

// MARK: - ContentPane

/// Switches the main content area based on the active `SidebarDestination`.
///
/// Search is handled at the view-model layer: when a query is active,
/// `LibraryViewModel` loads filtered data into the same VMs that each view
/// already observes.  No separate search panel is needed.
public struct ContentPane: View {
    @ObservedObject public var vm: LibraryViewModel

    public init(vm: LibraryViewModel) {
        self.vm = vm
    }

    public var body: some View {
        self.destinationContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch self.vm.selectedDestination {
        case .songs:
            TracksView(
                vm: self.vm.tracks,
                library: self.vm,
                sortable: true
            )

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

        case let .playlist(id):
            PlaylistDetailView(
                playlistID: id,
                library: self.vm,
                service: self.vm.playlistService
            )

        case let .folder(id):
            if let node = self.vm.playlistSidebar.findNode(id: id) {
                PlaylistFolderView(node: node, library: self.vm)
            } else if self.vm.playlistSidebar.isLoaded {
                // Sidebar has fully loaded — the folder is genuinely gone.
                ContentUnavailableView(
                    "Folder Not Found",
                    systemImage: "folder",
                    description: Text("This folder may have been deleted.")
                )
            }
            // else: sidebar not loaded yet — render nothing rather than
            // flashing an error on every startup.

        case let .smartPlaylist(id):
            SmartPlaylistDetailView(
                playlistID: id,
                library: self.vm,
                service: self.vm.smartPlaylistService
            )

        case .search:
            // Treat as Songs view; LibraryViewModel filters by the active query.
            TracksView(vm: self.vm.tracks, library: self.vm)
        }
    }
}
