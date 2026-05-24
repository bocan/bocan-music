import SwiftSonic
import SwiftUI

// MARK: - ContentPane

/// Switches the main content area based on the active `SidebarDestination`.
///
/// Search is handled at the view-model layer: when a query is active,
/// `LibraryViewModel` loads filtered data into the same VMs that each view
/// already observes.  No separate search panel is needed.
public struct ContentPane: View {
    @ObservedObject public var vm: LibraryViewModel
    /// Observed separately so changes to `isLoaded` / `nodes` on the sidebar
    /// VM trigger a re-render of ContentPane even though `playlistSidebar` is
    /// a plain `let` on `LibraryViewModel` (not `@Published`).
    @ObservedObject private var sidebar: PlaylistSidebarViewModel

    public init(vm: LibraryViewModel) {
        self.vm = vm
        self.sidebar = vm.playlistSidebar
    }

    public var body: some View {
        self.destinationContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if self.vm.isInitialScan {
                    ScanProgressPane(
                        walked: self.vm.scanWalked,
                        inserted: self.vm.scanInserted,
                        currentPath: self.vm.scanCurrentPath
                    )
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: self.vm.isInitialScan)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !self.vm.isInitialScan {
                    ScanBanner(vm: self.vm)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // Phase 19 step 13: federated Subsonic search results render
                // above the locally filtered list whenever the global search
                // field has content and at least one enabled server has
                // returned (or is returning) a result section.
                if let fs = self.vm.federatedSearch {
                    SubsonicSearchResultsPanel(
                        vm: fs,
                        library: self.vm,
                        coverArtProvider: self.vm.subsonicCoverArtProvider
                    )
                }
            }
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

        case let .subsonicSongs(serverID):
            if let ds = self.vm.subsonicDataSource {
                SubsonicSongsView(
                    serverID: serverID,
                    library: self.vm,
                    dataSource: ds,
                    coverArtProvider: self.vm.subsonicCoverArtProvider
                )
            } else {
                self.subsonicUnavailable
            }

        case let .subsonicAlbums(serverID):
            if let ds = self.vm.subsonicDataSource {
                SubsonicAlbumsView(
                    serverID: serverID,
                    library: self.vm,
                    dataSource: ds,
                    coverArtProvider: self.vm.subsonicCoverArtProvider
                )
            } else {
                self.subsonicUnavailable
            }

        case let .subsonicArtists(serverID):
            if let ds = self.vm.subsonicDataSource {
                SubsonicArtistsView(
                    serverID: serverID,
                    library: self.vm,
                    dataSource: ds,
                    coverArtProvider: self.vm.subsonicCoverArtProvider
                )
            } else {
                self.subsonicUnavailable
            }

        case let .subsonicGenres(serverID):
            if let ds = self.vm.subsonicDataSource {
                SubsonicGenresView(
                    serverID: serverID,
                    library: self.vm,
                    dataSource: ds,
                    coverArtProvider: self.vm.subsonicCoverArtProvider
                )
            } else {
                self.subsonicUnavailable
            }

        case let .subsonicPlaylists(serverID):
            if let ds = self.vm.subsonicDataSource {
                SubsonicPlaylistsView(
                    serverID: serverID,
                    library: self.vm,
                    dataSource: ds,
                    coverArtProvider: self.vm.subsonicCoverArtProvider
                )
            } else {
                self.subsonicUnavailable
            }

        case let .subsonicPlaylist(serverID, playlistID):
            if let ds = self.vm.subsonicDataSource {
                SubsonicPlaylistDetailView(
                    serverID: serverID,
                    playlistID: playlistID,
                    library: self.vm,
                    dataSource: ds,
                    coverArtProvider: self.vm.subsonicCoverArtProvider
                )
            } else {
                self.subsonicUnavailable
            }

        case let .subsonicStarred(serverID):
            if let ds = self.vm.subsonicDataSource {
                SubsonicStarredView(
                    serverID: serverID,
                    library: self.vm,
                    dataSource: ds,
                    coverArtProvider: self.vm.subsonicCoverArtProvider
                )
            } else {
                self.subsonicUnavailable
            }

        case let .subsonicRandom(serverID):
            if let ds = self.vm.subsonicDataSource {
                SubsonicSongsView(
                    serverID: serverID,
                    library: self.vm,
                    dataSource: ds,
                    coverArtProvider: self.vm.subsonicCoverArtProvider,
                    title: "Random"
                )
            } else {
                self.subsonicUnavailable
            }

        case let .subsonicRecentlyAdded(serverID):
            if let ds = self.vm.subsonicDataSource {
                SubsonicAlbumsView(
                    serverID: serverID,
                    library: self.vm,
                    dataSource: ds,
                    coverArtProvider: self.vm.subsonicCoverArtProvider,
                    listType: .newest,
                    title: "Recently Added"
                )
            } else {
                self.subsonicUnavailable
            }

        case let .subsonicMostPlayed(serverID):
            if let ds = self.vm.subsonicDataSource {
                SubsonicAlbumsView(
                    serverID: serverID,
                    library: self.vm,
                    dataSource: ds,
                    coverArtProvider: self.vm.subsonicCoverArtProvider,
                    listType: .frequent,
                    title: "Most Played"
                )
            } else {
                self.subsonicUnavailable
            }

        case let .subsonicInternetRadio(serverID):
            if let ds = self.vm.subsonicDataSource {
                SubsonicInternetRadioView(
                    serverID: serverID,
                    dataSource: ds
                )
            } else {
                self.subsonicUnavailable
            }

        case let .subsonicPodcasts(serverID):
            if let ds = self.vm.subsonicDataSource {
                SubsonicPodcastsView(
                    serverID: serverID,
                    dataSource: ds,
                    coverArtProvider: self.vm.subsonicCoverArtProvider
                )
            } else {
                self.subsonicUnavailable
            }

        case let .subsonicBookmarks(serverID):
            if let ds = self.vm.subsonicDataSource {
                SubsonicBookmarksView(
                    serverID: serverID,
                    library: self.vm,
                    dataSource: ds,
                    coverArtProvider: self.vm.subsonicCoverArtProvider
                )
            } else {
                self.subsonicUnavailable
            }
        }
    }

    private var subsonicUnavailable: some View {
        ContentUnavailableView(
            "Subsonic Unavailable",
            systemImage: "exclamationmark.icloud",
            description: Text("Sources aren't wired in to this build.")
        )
    }
}
