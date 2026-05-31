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
            "Songs"

        case .albums:
            "Albums"

        case .artists:
            "Artists"

        case .genres:
            "Genres"

        case .composers:
            "Composers"

        case .recentlyAdded:
            "Recently Added"

        case .recentlyPlayed:
            "Recently Played"

        case .mostPlayed:
            "Most Played"

        case .artist:
            "Artist"

        case .album:
            "Album"

        case let .genre(genre):
            genre

        case let .composer(composer):
            composer

        case .playlist:
            "Playlist"

        case .folder:
            "Folder"

        case .smartPlaylist:
            "Smart Playlist"

        case .upNext:
            "Up Next"

        case let .search(searchQuery):
            "Search: \(searchQuery)"

        case .subsonicSongs:
            "Songs"

        case .subsonicAlbums:
            "Albums"

        case .subsonicArtists:
            "Artists"

        case .subsonicGenres:
            "Genres"

        case .subsonicPlaylists:
            "Playlists"

        case .subsonicPlaylist:
            "Playlist"

        case .subsonicStarred:
            "Starred"

        case .subsonicRandom:
            "Random"

        case .subsonicRecentlyAdded:
            "Recently Added"

        case .subsonicMostPlayed:
            "Most Played"

        case .subsonicInternetRadio:
            "Internet Radio"

        case .subsonicPodcasts:
            "Podcasts"

        case .subsonicBookmarks:
            "Bookmarks"

        case .subsonicRoot:
            "Songs"

        case .subsonicArtist:
            "Artist"

        case .subsonicAlbum:
            "Album"
        }
    }
}
