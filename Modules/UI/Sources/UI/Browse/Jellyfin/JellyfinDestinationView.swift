import SwiftUI

// MARK: - JellyfinDestinationView

/// Turns a Jellyfin `SidebarDestination` into its browse view (ADR-097).
///
/// `ContentPane` sends every Jellyfin case here, so its own switch gains one arm
/// and the Jellyfin routing sits beside the views it routes to. The nine sidebar
/// rows map onto five views: Songs, Random and Most Played are one songs view in
/// three modes, and Albums and Recently Added are one albums grid in two orders.
struct JellyfinDestinationView: View {
    let destination: SidebarDestination
    @ObservedObject var library: LibraryViewModel

    var body: some View {
        if let serverID = self.destination.jellyfinServerID, let dataSource = self.library.jellyfin.dataSource {
            self.content(serverID: serverID, dataSource: dataSource)
        } else {
            ContentUnavailableView(
                L10n.string("Jellyfin Unavailable"),
                systemImage: "exclamationmark.icloud",
                description: Text(localized: "Sources aren't wired in to this build.")
            )
        }
    }

    @ViewBuilder
    private func content(serverID: UUID, dataSource: any JellyfinBrowseDataSource) -> some View {
        switch self.destination {
        case let .jellyfinPlaylist(_, playlistID):
            JellyfinPlaylistDetailView(
                serverID: serverID,
                playlistID: playlistID,
                library: self.library,
                dataSource: dataSource,
                coverArtProvider: self.library.jellyfin.coverArtProvider
            )

        case let .jellyfinArtist(_, artistID):
            JellyfinArtistDetailView(
                serverID: serverID,
                artistID: artistID,
                library: self.library,
                dataSource: dataSource,
                coverArtProvider: self.library.jellyfin.coverArtProvider
            )

        case let .jellyfinAlbum(_, albumID):
            JellyfinAlbumDetailView(
                serverID: serverID,
                albumID: albumID,
                library: self.library,
                dataSource: dataSource,
                coverArtProvider: self.library.jellyfin.coverArtProvider
            )

        default:
            self.listContent(serverID: serverID, dataSource: dataSource)
        }
    }

    /// The nine rows of the sidebar.
    @ViewBuilder
    private func listContent(serverID: UUID, dataSource: any JellyfinBrowseDataSource) -> some View {
        let cover = self.library.jellyfin.coverArtProvider
        switch self.destination {
        case .jellyfinRoot, .jellyfinSongs:
            JellyfinSongsView(serverID: serverID, library: self.library, dataSource: dataSource, coverArtProvider: cover)

        case .jellyfinRandom:
            JellyfinSongsView(
                serverID: serverID,
                library: self.library,
                dataSource: dataSource,
                coverArtProvider: cover,
                source: .random,
                title: L10n.string("Random")
            )

        case .jellyfinMostPlayed:
            JellyfinSongsView(
                serverID: serverID,
                library: self.library,
                dataSource: dataSource,
                coverArtProvider: cover,
                source: .mostPlayed,
                title: L10n.string("Most Played")
            )

        case .jellyfinAlbums:
            JellyfinAlbumsView(serverID: serverID, library: self.library, dataSource: dataSource, coverArtProvider: cover)

        case .jellyfinRecentlyAdded:
            JellyfinAlbumsView(
                serverID: serverID,
                library: self.library,
                dataSource: dataSource,
                coverArtProvider: cover,
                list: .recentlyAdded,
                title: L10n.string("Recently Added")
            )

        case .jellyfinArtists:
            JellyfinArtistsView(serverID: serverID, library: self.library, dataSource: dataSource, coverArtProvider: cover)

        case .jellyfinGenres:
            JellyfinGenresView(serverID: serverID, library: self.library, dataSource: dataSource, coverArtProvider: cover)

        case .jellyfinPlaylists:
            JellyfinPlaylistsView(serverID: serverID, library: self.library, dataSource: dataSource, coverArtProvider: cover)

        case .jellyfinStarred:
            JellyfinStarredView(serverID: serverID, library: self.library, dataSource: dataSource, coverArtProvider: cover)

        default:
            EmptyView()
        }
    }
}
