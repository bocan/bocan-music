import Jellyfin
import SwiftUI

// MARK: - JellyfinGenresView

/// Per-server Genres destination (ADR-097): the genre list on the left and the
/// songs of the chosen genre on the right, paged as the table scrolls.
public struct JellyfinGenresView: View {
    public let serverID: UUID
    @ObservedObject public var library: LibraryViewModel
    public let coverArtProvider: JellyfinCoverArtProvider?
    private let dataSource: any JellyfinBrowseDataSource

    @StateObject private var vm: JellyfinGenresViewModel
    @State private var selectedGenre: JellyfinGenre?

    public init(
        serverID: UUID,
        library: LibraryViewModel,
        dataSource: any JellyfinBrowseDataSource,
        coverArtProvider: JellyfinCoverArtProvider?
    ) {
        self.serverID = serverID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self.dataSource = dataSource
        self._vm = StateObject(
            wrappedValue: JellyfinGenresViewModel(
                serverID: serverID,
                dataSource: dataSource,
                cache: library.jellyfin.metadataCache
            )
        )
    }

    public var body: some View {
        HSplitView {
            self.genreList
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)

            self.songsPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(L10n.string("Genres"))
        .task(id: self.serverID) {
            if self.vm.genres.isEmpty {
                await self.vm.load()
            }
        }
        .loadErrorAlert(L10n.string("Couldn't load genres"), message: self.$vm.errorMessage)
    }

    @ViewBuilder
    private var genreList: some View {
        if self.vm.genres.isEmpty, !self.vm.isLoading {
            ContentUnavailableView(
                L10n.string("No Genres"),
                systemImage: "tag",
                description: Text(localized: "This server hasn't returned any genres.")
            )
        } else {
            List(selection: Binding(
                get: { self.selectedGenre?.id },
                set: { id in self.selectedGenre = self.vm.genres.first { $0.id == id } }
            )) {
                ForEach(self.vm.genres) { genre in
                    HStack {
                        Text(genre.name)
                            .font(Typography.subheadline)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        if let count = genre.songCount {
                            Text(verbatim: String(count))
                                .font(Typography.caption.monospacedDigit())
                                .foregroundStyle(Color.textTertiary)
                        }
                    }
                    .tag(genre.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(genre.songCount.map { L10n.string("\(genre.name), \($0) songs") } ?? genre.name)
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var songsPane: some View {
        if let genre = self.selectedGenre {
            // One pane per genre: the id makes a new genre start a new model.
            JellyfinGenreSongsPane(
                genre: genre,
                serverID: self.serverID,
                library: self.library,
                dataSource: self.dataSource,
                coverArtProvider: self.coverArtProvider
            )
            .id(genre.id)
        } else {
            ContentUnavailableView(
                L10n.string("Select a Genre"),
                systemImage: "tag",
                description: Text(localized: "Pick a genre on the left to browse its songs.")
            )
        }
    }
}

// MARK: - JellyfinGenreSongsPane

private struct JellyfinGenreSongsPane: View {
    let genre: JellyfinGenre
    let serverID: UUID
    let library: LibraryViewModel
    let coverArtProvider: JellyfinCoverArtProvider?

    @StateObject private var model: JellyfinGenreSongsModel
    @ObservedObject private var jellyfin: JellyfinSourceModel

    init(
        genre: JellyfinGenre,
        serverID: UUID,
        library: LibraryViewModel,
        dataSource: any JellyfinBrowseDataSource,
        coverArtProvider: JellyfinCoverArtProvider?
    ) {
        self.genre = genre
        self.serverID = serverID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self.jellyfin = library.jellyfin
        self._model = StateObject(
            wrappedValue: JellyfinGenreSongsModel(
                serverID: serverID,
                genreID: genre.id,
                dataSource: dataSource,
                serverName: library.jellyfin.servers.first { $0.id == serverID }?.name ?? ""
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(self.genre.name)
                    .font(Typography.title)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text(localized: "\(self.model.songs.count) songs")
                    .font(Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            if self.model.songs.isEmpty, !self.model.isLoading {
                ContentUnavailableView(
                    L10n.string("No Songs"),
                    systemImage: "music.note",
                    description: Text(localized: "This genre has no songs to display.")
                )
            } else if self.model.songs.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                JellyfinSongListTable(
                    model: self.model,
                    library: self.library,
                    coverArtProvider: self.coverArtProvider,
                    hasMorePages: self.model.hasMorePages
                ) {
                    Task { await self.model.loadMore() }
                }
            }
        }
        .task {
            if self.model.songs.isEmpty {
                await self.model.loadMore()
            }
        }
        .jellyfinServerName(self.jellyfin, serverID: self.serverID) { self.model.serverName = $0 }
        .loadErrorAlert(L10n.string("Couldn't load songs"), message: self.$model.errorMessage)
    }
}
