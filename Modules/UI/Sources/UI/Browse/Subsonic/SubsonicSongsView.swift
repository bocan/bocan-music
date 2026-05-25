import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicSongsView

/// Per-server Songs destination (Phase 19 step 10).
///
/// Subsonic has no global "all songs" endpoint, so this view presents a
/// shuffled sample fetched via `getRandomSongs`.  The toolbar offers a
/// Refresh action to reseed the sample, and the table lazy-loads further
/// pages as the user scrolls toward the bottom.
public struct SubsonicSongsView: View {
    public let serverID: UUID
    public let library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?
    public let title: String

    @StateObject private var vm: SubsonicSongsViewModel
    @Environment(\.subsonicAnnotationCoordinator) private var annotationCoordinator

    public init(
        serverID: UUID,
        library: LibraryViewModel,
        dataSource: any SubsonicBrowseDataSource,
        coverArtProvider: SubsonicCoverArtProvider?,
        title: String = "Songs"
    ) {
        self.serverID = serverID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self.title = title
        self._vm = StateObject(
            wrappedValue: SubsonicSongsViewModel(
                serverID: serverID,
                dataSource: dataSource,
                cache: library.subsonicMetadataCache
            )
        )
    }

    public var body: some View {
        Group {
            if self.vm.songs.isEmpty, !self.vm.isLoading {
                self.emptyState
            } else {
                SubsonicSongTable(
                    serverID: self.serverID,
                    rows: self.buildRows(),
                    isLoading: self.vm.isLoading,
                    hasMorePages: self.vm.hasMorePages,
                    coverArtProvider: self.coverArtProvider,
                    actions: SubsonicSongTableActions(
                        playNow: { index in
                            let songs = self.vm.songs
                            let sid = self.serverID
                            Task { await self.library.play(subsonicSongs: songs, serverID: sid, startingAt: index) }
                        },
                        loadMore: {
                            Task { await self.vm.loadMore() }
                        },
                        toggleStar: { songID in
                            guard let coord = self.annotationCoordinator else { return }
                            let song = self.vm.songs.first { $0.id == songID }
                            let starred = coord.isStarred(songID: songID, serverStarred: song?.starred)
                            coord.toggleStar(songID: songID, serverID: self.serverID, currentlyStarred: starred)
                        },
                        setRating: { songID, stars in
                            guard let coord = self.annotationCoordinator else { return }
                            let song = self.vm.songs.first { $0.id == songID }
                            coord.setRating(
                                songID: songID,
                                serverID: self.serverID,
                                newRating: stars,
                                previousRating: song?.userRating
                            )
                        }
                    )
                )
            }
        }
        .navigationTitle(self.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await self.vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(self.vm.isLoading)
            }
        }
        .task(id: self.serverID) {
            if self.vm.songs.isEmpty { await self.vm.load() }
        }
        .alert(
            "Couldn't load songs",
            isPresented: Binding(
                get: { self.vm.errorMessage != nil },
                set: { if !$0 { self.vm.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(self.vm.errorMessage ?? "") }
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        if self.vm.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Songs",
                systemImage: "music.note",
                description: Text("This server hasn't returned any songs yet.")
            )
        }
    }

    /// Builds table rows from the current songs, incorporating live
    /// star/rating overrides from the annotation coordinator when present.
    private func buildRows() -> [SubsonicSongTableRow] {
        self.vm.songs.map { song in
            SubsonicSongTableRow(
                song: song,
                starred: self.annotationCoordinator?.isStarred(
                    songID: song.id,
                    serverStarred: song.starred
                ) ?? (song.starred != nil),
                rating: self.annotationCoordinator?.rating(
                    songID: song.id,
                    serverRating: song.userRating
                ) ?? (song.userRating ?? 0)
            )
        }
    }
}
