import Observability
import Persistence
import SwiftUI

// MARK: - SmartFolderView

/// Read-only track-list view backed by a pre-computed smart-folder query.
///
/// Supported destinations: `.recentlyAdded`, `.recentlyPlayed`, `.mostPlayed`.
public struct SmartFolderView: View {
    public var vm: TracksViewModel
    public var library: LibraryViewModel
    public var destination: SidebarDestination

    public init(vm: TracksViewModel, library: LibraryViewModel, destination: SidebarDestination) {
        self.vm = vm
        self.library = library
        self.destination = destination
    }

    public var body: some View {
        TracksView(vm: self.vm, library: self.library, title: self.destination.displayTitle)
            .task {
                let repo = TrackRepository(database: library.database)
                let result: [Track]
                do {
                    switch self.destination {
                    case .recentlyAdded:
                        result = try await repo.recentlyAdded(days: 30)

                    case .recentlyPlayed:
                        result = try await repo.recentlyPlayed(days: 90)

                    case .mostPlayed:
                        result = try await repo.mostPlayed(limit: 100)

                    default:
                        result = []
                    }
                    self.vm.setTracks(result)
                } catch {
                    AppLogger.make(.ui).error(
                        "smartfolder.load.failed",
                        ["destination": String(describing: self.destination), "error": String(reflecting: error)]
                    )
                }
            }
    }
}

// MARK: - SidebarDestination + displayTitle

extension SidebarDestination {
    var displayTitle: String {
        switch self {
        case .songs:
            L10n.string("Songs")

        case .albums:
            L10n.string("Albums")

        case .artists:
            L10n.string("Artists")

        case .genres:
            L10n.string("Genres")

        case .composers:
            L10n.string("Composers")

        case .recentlyAdded:
            L10n.string("Recently Added")

        case .recentlyPlayed:
            L10n.string("Recently Played")

        case .mostPlayed:
            L10n.string("Most Played")

        case .artist:
            L10n.string("Artist")

        case .album:
            L10n.string("Album")

        case let .genre(genre):
            genre

        case let .composer(composer):
            composer

        case .playlist:
            L10n.string("Playlist")

        case .folder:
            L10n.string("Folder")

        case .smartPlaylist:
            L10n.string("Smart Playlist")

        case .upNext:
            L10n.string("Up Next")

        case let .search(searchQuery):
            L10n.string("Search: \(searchQuery)")

        case .subsonicSongs:
            L10n.string("Songs")

        case .subsonicAlbums:
            L10n.string("Albums")

        case .subsonicArtists:
            L10n.string("Artists")

        case .subsonicGenres:
            L10n.string("Genres")

        case .subsonicPlaylists:
            L10n.string("Playlists")

        case .subsonicPlaylist:
            L10n.string("Playlist")

        case .subsonicStarred:
            L10n.string("Starred")

        case .subsonicRandom:
            L10n.string("Random")

        case .subsonicRecentlyAdded:
            L10n.string("Recently Added")

        case .subsonicMostPlayed:
            L10n.string("Most Played")

        case .subsonicInternetRadio:
            L10n.string("Internet Radio")

        case .subsonicPodcasts:
            L10n.string("Podcasts")

        case .subsonicBookmarks:
            L10n.string("Bookmarks")

        case .subsonicRoot:
            L10n.string("Songs")

        case .subsonicArtist:
            L10n.string("Artist")

        case .subsonicAlbum:
            L10n.string("Album")

        case .podcasts:
            L10n.string("Podcasts")

        case .podcastShow:
            L10n.string("Podcast")
        }
    }
}
