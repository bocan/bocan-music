import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicSongsView

/// Per-server Songs destination (Phase 19 step 10).
///
/// Subsonic has no global "all songs" endpoint, so the un-filtered list is
/// a shuffled sample fetched via `getRandomSongs`. Refresh reseeds the
/// sample; the table lazy-loads further pages as the user scrolls.
///
/// When `library.searchQuery` is non-empty the view switches to multi-source
/// search results — songs aggregated across every enabled Subsonic server
/// via `search3`. The same NSTableView renders both modes; in search mode
/// the table gains a "Source" column.
public struct SubsonicSongsView: View {
    public let serverID: UUID
    @ObservedObject public var library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?
    public let title: String

    @StateObject private var vm: SubsonicSongsViewModel
    @ObservedObject private var search: SubsonicMultiSourceSearchViewModel
    @Environment(\.subsonicAnnotationCoordinator) private var annotationCoordinator

    public init(
        serverID: UUID,
        library: LibraryViewModel,
        dataSource: any SubsonicBrowseDataSource,
        coverArtProvider: SubsonicCoverArtProvider?,
        title: String? = nil
    ) {
        self.serverID = serverID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self.title = title ?? L10n.string("Songs")
        self._vm = StateObject(
            wrappedValue: SubsonicSongsViewModel(
                serverID: serverID,
                dataSource: dataSource,
                cache: library.subsonicMetadataCache
            )
        )
        // Safe: `subsonicSearch` is always non-nil whenever this view is
        // reachable (the view only routes for Subsonic destinations, which
        // implies the data source — and therefore the search VM — exist).
        // The fallback exists only so previews/snapshots stay safe.
        self.search = library.subsonicSearch
            ?? SubsonicMultiSourceSearchViewModel(dataSource: NoopBrowseDataSource())
    }

    private var isSearching: Bool {
        !self.library.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Row ID of the currently-playing Subsonic stream, so the table can move its
    /// selection onto the playing song (mirrors the local library).
    private var nowPlayingRowID: String? {
        let np = self.library.nowPlaying
        guard let serverID = np.nowPlayingSubsonicServerID,
              let songID = np.nowPlayingSubsonicSongID else { return nil }
        return SubsonicSongTableRow.id(serverID: serverID, songID: songID)
    }

    public var body: some View {
        Group {
            if self.isSearching {
                self.searchBody
            } else {
                self.regularBody
            }
        }
        .navigationTitle(self.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await self.vm.refresh() }
                } label: {
                    Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(self.vm.isLoading || self.isSearching)
                .help(self.isSearching ? L10n.string("Refresh is disabled during search") : L10n.string("Reshuffle the sample"))
            }
        }
        .task(id: self.serverID) {
            if self.vm.songs.isEmpty { await self.vm.load() }
        }
        .loadErrorAlert(L10n.string("Couldn't load songs"), message: self.$vm.errorMessage)
    }

    // MARK: - Regular mode (no search)

    @ViewBuilder
    private var regularBody: some View {
        if self.vm.songs.isEmpty, !self.vm.isLoading {
            ContentUnavailableView(
                L10n.string("No Songs"),
                systemImage: "music.note",
                description: Text(localized: "This server hasn't returned any songs yet.")
            )
        } else if self.vm.songs.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let serverName = self.currentServerName
            let rows = self.vm.songs.map { song in
                SubsonicSongTableRow(
                    song: song,
                    serverID: self.serverID,
                    serverName: serverName,
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
            SubsonicSongTable(
                rows: rows,
                isLoading: self.vm.isLoading,
                hasMorePages: self.vm.hasMorePages,
                coverArtProvider: self.coverArtProvider,
                showsSource: false,
                nowPlayingRowID: self.nowPlayingRowID,
                actions: SubsonicSongTableActions(
                    playNow: { index in
                        let songs = self.vm.songs
                        let sid = self.serverID
                        Task {
                            await self.library.play(
                                subsonicSongs: songs, serverID: sid, startingAt: index
                            )
                        }
                    },
                    loadMore: { Task { await self.vm.loadMore() } },
                    toggleStar: { songID in
                        guard let coord = self.annotationCoordinator else { return }
                        let song = self.vm.songs.first { $0.id == songID }
                        let starred = coord.isStarred(songID: songID, serverStarred: song?.starred)
                        coord.toggleStar(
                            songID: songID,
                            serverID: self.serverID,
                            currentlyStarred: starred
                        )
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
            .id("regular")
        }
    }

    // MARK: - Search mode (multi-source)

    @ViewBuilder
    private var searchBody: some View {
        if self.search.songs.isEmpty {
            if self.search.isSearching {
                ProgressView(L10n.string("Searching…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: self.library.searchQuery)
            }
        } else {
            let rows = self.search.songs.map { hit in
                SubsonicSongTableRow(
                    song: hit.song,
                    serverID: hit.serverID,
                    serverName: hit.serverName,
                    starred: self.annotationCoordinator?.isStarred(
                        songID: hit.song.id,
                        serverStarred: hit.song.starred
                    ) ?? (hit.song.starred != nil),
                    rating: self.annotationCoordinator?.rating(
                        songID: hit.song.id,
                        serverRating: hit.song.userRating
                    ) ?? (hit.song.userRating ?? 0)
                )
            }
            VStack(spacing: 0) {
                if !self.search.failedServerNames.isEmpty {
                    SubsonicSearchFailedBanner(serverNames: self.search.failedServerNames)
                }
                SubsonicSongTable(
                    rows: rows,
                    isLoading: self.search.isSearching,
                    hasMorePages: false,
                    coverArtProvider: self.coverArtProvider,
                    showsSource: true,
                    nowPlayingRowID: self.nowPlayingRowID,
                    actions: SubsonicSongTableActions(
                        playNow: { index in
                            let hits = self.search.songs
                            Task {
                                await self.library.play(
                                    subsonicMultiSource: hits, startingAt: index
                                )
                            }
                        },
                        loadMore: {},
                        toggleStar: { songID in
                            guard let coord = self.annotationCoordinator else { return }
                            guard let hit = self.search.songs.first(where: { $0.song.id == songID }) else {
                                return
                            }
                            let starred = coord.isStarred(songID: songID, serverStarred: hit.song.starred)
                            coord.toggleStar(
                                songID: songID,
                                serverID: hit.serverID,
                                currentlyStarred: starred
                            )
                        },
                        setRating: { songID, stars in
                            guard let coord = self.annotationCoordinator else { return }
                            guard let hit = self.search.songs.first(where: { $0.song.id == songID }) else {
                                return
                            }
                            coord.setRating(
                                songID: songID,
                                serverID: hit.serverID,
                                newRating: stars,
                                previousRating: hit.song.userRating
                            )
                        }
                    )
                )
                .id("search")
            }
        }
    }

    private var currentServerName: String {
        self.library.subsonicServers.first { $0.id == self.serverID }?.name ?? ""
    }
}
