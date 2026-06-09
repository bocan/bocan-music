import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicAlbumsView

/// Per-server Albums destination (Phase 19 step 10). Paged grid fetched via
/// `getAlbumList2`. When the global search field has text, the same grid
/// renders multi-source search results aggregated across every enabled
/// Subsonic server, with each cell decorated with a small source pill.
public struct SubsonicAlbumsView: View {
    public let serverID: UUID
    @ObservedObject public var library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?
    public let title: String

    @StateObject private var vm: SubsonicAlbumsViewModel
    /// Separately observed so the view re-renders when the multi-source
    /// search VM publishes new `albums` / `isSearching` / `failedServerNames`
    /// values. Without this, reading `library.subsonicSearch?.…` only
    /// triggers a redraw when `library` itself publishes — and the view
    /// would freeze on "Searching\u{2026}" until the user navigated away
    /// and back.
    @ObservedObject private var search: SubsonicMultiSourceSearchViewModel
    @ScaledMetric(relativeTo: .body) private var minWidth = Theme.albumGridMinWidth

    public init(
        serverID: UUID,
        library: LibraryViewModel,
        dataSource: any SubsonicBrowseDataSource,
        coverArtProvider: SubsonicCoverArtProvider?,
        listType: AlbumListType = .alphabeticalByName,
        title: String = "Albums"
    ) {
        self.serverID = serverID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self.title = title
        self._vm = StateObject(
            wrappedValue: SubsonicAlbumsViewModel(
                serverID: serverID,
                dataSource: dataSource,
                cache: library.subsonicMetadataCache,
                listType: listType
            )
        )
        self.search = library.subsonicSearch
            ?? SubsonicMultiSourceSearchViewModel(dataSource: NoopBrowseDataSource())
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
            if self.vm.albums.isEmpty { await self.vm.load() }
        }
        .alert(
            L10n.string("Couldn't load albums"),
            isPresented: Binding(
                get: { self.vm.errorMessage != nil },
                set: { if !$0 { self.vm.errorMessage = nil } }
            ),
            actions: { Button(L10n.string("OK"), role: .cancel) {} },
            message: { Text(self.vm.errorMessage ?? "") }
        )
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
                        SubsonicAlbumCell(
                            album: album,
                            serverID: self.serverID,
                            sourceName: nil,
                            coverArtProvider: self.coverArtProvider
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let sid = self.serverID
                            let aid = album.id
                            Task { await self.library.selectDestination(.subsonicAlbum(sid, aid)) }
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
                let failed = self.search.failedServerNames
                if !failed.isEmpty {
                    SubsonicSearchFailedBanner(serverNames: failed)
                }
                LazyVGrid(columns: self.columns, spacing: Theme.albumGridSpacing) {
                    ForEach(hits) { hit in
                        SubsonicAlbumCell(
                            album: hit.album,
                            serverID: hit.serverID,
                            sourceName: hit.serverName,
                            coverArtProvider: self.coverArtProvider
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let sid = hit.serverID
                            let aid = hit.album.id
                            Task { await self.library.selectDestination(.subsonicAlbum(sid, aid)) }
                        }
                    }
                }
                .padding(Theme.albumGridSpacing)
            }
        }
    }
}

// MARK: - SubsonicAlbumCell

private struct SubsonicAlbumCell: View {
    let album: AlbumID3
    let serverID: UUID
    /// When non-nil, a small "source" pill is drawn over the artwork.
    /// `nil` for single-server browse to keep the cell clean.
    let sourceName: String?
    let coverArtProvider: SubsonicCoverArtProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SubsonicCoverImage(
                provider: self.coverArtProvider,
                serverID: self.serverID,
                entityID: self.album.coverArt,
                seed: abs(self.album.id.hashValue),
                pixelSize: Int(Theme.albumGridMinWidth * 2)
            )
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                if let name = self.sourceName, !name.isEmpty {
                    SubsonicSourcePill(name: name)
                        .padding(6)
                }
            }

            Text(self.album.name)
                .font(Typography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            Text(self.album.artist ?? L10n.string("Various Artists"))
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)

            let yearString = self.album.year.map { String($0) }
            let countString = L10n.string("\(self.album.songCount) songs")
            let subtitle = [yearString, countString].compactMap(\.self).joined(separator: " · ")
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [self.album.name, self.album.artist, self.album.year.map(String.init), self.sourceName]
                .compactMap(\.self)
                .joined(separator: ", ")
        )
    }
}
