import Persistence
import SwiftUI

// MARK: - SmartFolderView

/// Read-only track-list view backed by a pre-computed smart-folder query.
///
/// Supported destinations: `.recentlyAdded`, `.recentlyPlayed`, `.mostPlayed`.
public struct SmartFolderView: View {
    @ObservedObject public var vm: TracksViewModel
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
                } catch {}
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
        }
    }
}
