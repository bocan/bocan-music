import Jellyfin
import SwiftUI

// MARK: - JellyfinSongsView

/// Per-server Songs, Random and Most Played destinations (ADR-097).
///
/// Songs is the whole library, paged as the table scrolls. When the search field
/// has text the same table shows the songs found across every Jellyfin server
/// that takes part in global search, with a "Source" column.
public struct JellyfinSongsView: View {
    public let serverID: UUID
    @ObservedObject public var library: LibraryViewModel
    public let coverArtProvider: JellyfinCoverArtProvider?
    public let title: String
    public let source: JellyfinSongsSource

    @StateObject private var vm: JellyfinSongsViewModel
    /// Observed separately, so the view redraws when the search model publishes.
    @ObservedObject private var search: JellyfinMultiSourceSearchViewModel
    @ObservedObject private var jellyfin: JellyfinSourceModel

    public init(
        serverID: UUID,
        library: LibraryViewModel,
        dataSource: any JellyfinBrowseDataSource,
        coverArtProvider: JellyfinCoverArtProvider?,
        source: JellyfinSongsSource = .all,
        title: String? = nil
    ) {
        self.serverID = serverID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self.source = source
        self.title = title ?? L10n.string("Songs")
        self._vm = StateObject(
            wrappedValue: JellyfinSongsViewModel(
                serverID: serverID,
                dataSource: dataSource,
                cache: library.jellyfin.metadataCache,
                source: source,
                serverName: library.jellyfin.servers.first { $0.id == serverID }?.name ?? ""
            )
        )
        self.jellyfin = library.jellyfin
        // The search model exists whenever a data source does. The fallback only keeps previews safe.
        self.search = library.jellyfin.search
            ?? JellyfinMultiSourceSearchViewModel(dataSource: NoopJellyfinBrowseDataSource())
    }

    private var isSearching: Bool {
        !self.library.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            if self.source != .all {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await self.vm.refresh() }
                    } label: {
                        Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                    }
                    .disabled(self.vm.isLoading || self.isSearching)
                    .help(self.refreshHelp)
                }
            }
        }
        .task(id: self.serverID) {
            if self.vm.songs.isEmpty {
                await self.vm.load()
            }
        }
        .jellyfinServerName(self.jellyfin, serverID: self.serverID) { self.vm.serverName = $0 }
        .loadErrorAlert(L10n.string("Couldn't load songs"), message: self.$vm.errorMessage)
    }

    private var refreshHelp: String {
        if self.isSearching {
            return L10n.string("Refresh is disabled during search")
        }
        return self.source == .random
            ? L10n.string("Draws a new random selection of songs.")
            : L10n.string("Fetches this list from the server again.")
    }

    // MARK: Regular mode

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
            JellyfinSongListTable(
                model: self.vm,
                library: self.library,
                coverArtProvider: self.coverArtProvider,
                hasMorePages: self.vm.hasMorePages
            ) {
                Task { await self.vm.loadMore() }
            }
            .id("regular")
        }
    }

    // MARK: Search mode

    @ViewBuilder
    private var searchBody: some View {
        if self.search.songs.isEmpty {
            if self.search.isSearching {
                ProgressView(L10n.string("Searching\u{2026}"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: self.library.searchQuery)
            }
        } else {
            VStack(spacing: 0) {
                if !self.search.failedServerNames.isEmpty {
                    SubsonicSearchFailedBanner(serverNames: self.search.failedServerNames)
                }
                JellyfinSongTable(
                    rows: self.search.rows,
                    rowsVersion: self.search.rowsVersion,
                    isLoading: self.search.isSearching,
                    hasMorePages: false,
                    coverArtProvider: self.coverArtProvider,
                    showsSource: true,
                    nowPlayingRowID: self.library.nowPlaying.jellyfinRowID,
                    actions: JellyfinSongTableActions(
                        playNow: { index in
                            let hits = self.search.songs
                            Task { await self.library.play(jellyfinMultiSource: hits, startingAt: index) }
                        },
                        loadMore: {}
                    )
                )
                .id("search")
            }
        }
    }
}
