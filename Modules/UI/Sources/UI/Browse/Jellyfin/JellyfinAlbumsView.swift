import Jellyfin
import SwiftUI

// MARK: - JellyfinAlbumsView

/// Per-server Albums and Recently Added destinations (ADR-097): a paged grid.
/// When the search field has text the same grid shows the albums found across
/// every Jellyfin server in global search, each cell marked with its source.
public struct JellyfinAlbumsView: View {
    public let serverID: UUID
    @ObservedObject public var library: LibraryViewModel
    public let coverArtProvider: JellyfinCoverArtProvider?
    public let title: String

    @StateObject private var vm: JellyfinAlbumsViewModel
    /// Observed separately, so the view redraws when the search model publishes.
    /// Reading it through `library` would freeze the view on "Searching".
    @ObservedObject private var search: JellyfinMultiSourceSearchViewModel
    @ScaledMetric(relativeTo: .body) private var minWidth = Theme.albumGridMinWidth

    public init(
        serverID: UUID,
        library: LibraryViewModel,
        dataSource: any JellyfinBrowseDataSource,
        coverArtProvider: JellyfinCoverArtProvider?,
        list: JellyfinAlbumList = .alphabetical,
        title: String? = nil
    ) {
        self.serverID = serverID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self.title = title ?? L10n.string("Albums")
        self._vm = StateObject(
            wrappedValue: JellyfinAlbumsViewModel(
                serverID: serverID,
                dataSource: dataSource,
                cache: library.jellyfin.metadataCache,
                list: list
            )
        )
        self.search = library.jellyfin.search
            ?? JellyfinMultiSourceSearchViewModel(dataSource: NoopJellyfinBrowseDataSource())
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: self.minWidth), spacing: Theme.albumGridSpacing)]
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
        .task(id: self.serverID) {
            if self.vm.albums.isEmpty {
                await self.vm.load()
            }
        }
        .loadErrorAlert(L10n.string("Couldn't load albums"), message: self.$vm.errorMessage)
    }

    @ViewBuilder
    private var regularBody: some View {
        if self.vm.albums.isEmpty, !self.vm.isLoading {
            ContentUnavailableView(
                L10n.string("No Albums"),
                systemImage: "square.grid.2x2",
                description: Text(localized: "This server hasn't returned any albums yet.")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: self.columns, spacing: Theme.albumGridSpacing) {
                    ForEach(self.vm.albums) { album in
                        JellyfinAlbumCell(
                            album: album,
                            serverID: self.serverID,
                            sourceName: nil,
                            coverArtProvider: self.coverArtProvider
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let serverID = self.serverID
                            Task { await self.library.selectDestination(.jellyfinAlbum(serverID, album.id)) }
                        }
                        .onAppear {
                            if album.id == self.vm.albums.last?.id, self.vm.hasMorePages {
                                Task { await self.vm.loadMore() }
                            }
                        }
                    }
                }
                .padding(Theme.albumGridSpacing)

                if self.vm.isLoading {
                    ProgressView().padding(.vertical, 12)
                }
            }
        }
    }

    @ViewBuilder
    private var searchBody: some View {
        let hits = self.search.albums
        if hits.isEmpty {
            if self.search.isSearching {
                ProgressView(L10n.string("Searching\u{2026}"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: self.library.searchQuery)
            }
        } else {
            ScrollView {
                if !self.search.failedServerNames.isEmpty {
                    SubsonicSearchFailedBanner(serverNames: self.search.failedServerNames)
                }
                LazyVGrid(columns: self.columns, spacing: Theme.albumGridSpacing) {
                    ForEach(hits) { hit in
                        JellyfinAlbumCell(
                            album: hit.album,
                            serverID: hit.serverID,
                            sourceName: hit.serverName,
                            coverArtProvider: self.coverArtProvider
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task { await self.library.selectDestination(.jellyfinAlbum(hit.serverID, hit.album.id)) }
                        }
                    }
                }
                .padding(Theme.albumGridSpacing)
            }
        }
    }
}
