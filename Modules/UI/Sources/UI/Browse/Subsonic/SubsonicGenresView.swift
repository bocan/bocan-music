import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicGenresView

/// Per-server Genres destination (Phase 19 step 10).
///
/// Split layout: the genre list on the left, the songs in the selected
/// genre on the right (paged via `getSongsByGenre`).
public struct SubsonicGenresView: View {
    public let serverID: UUID
    public let library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?

    @StateObject private var vm: SubsonicGenresViewModel

    public init(
        serverID: UUID,
        library: LibraryViewModel,
        dataSource: any SubsonicBrowseDataSource,
        coverArtProvider: SubsonicCoverArtProvider?
    ) {
        self.serverID = serverID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self._vm = StateObject(
            wrappedValue: SubsonicGenresViewModel(
                serverID: serverID,
                dataSource: dataSource,
                cache: library.subsonicMetadataCache
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
            if self.vm.genres.isEmpty { await self.vm.load() }
        }
        .alert(
            L10n.string("Couldn't load genres"),
            isPresented: Binding(
                get: { self.vm.errorMessage != nil },
                set: { if !$0 { self.vm.errorMessage = nil } }
            ),
            actions: { Button(L10n.string("OK"), role: .cancel) {} },
            message: { Text(self.vm.errorMessage ?? "") }
        )
    }

    @ViewBuilder
    private var genreList: some View {
        if self.vm.genres.isEmpty, !self.vm.isLoadingGenres {
            ContentUnavailableView(
                L10n.string("No Genres"),
                systemImage: "tag",
                description: Text(localized: "This server hasn't returned any genres.")
            )
        } else {
            List(selection: Binding(
                get: { self.vm.selectedGenre },
                set: { newValue in Task { await self.vm.selectGenre(newValue) } }
            )) {
                ForEach(self.vm.genres, id: \.value) { genre in
                    HStack {
                        Text(genre.value)
                            .font(Typography.subheadline)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(verbatim: String(genre.songCount))
                            .font(Typography.caption.monospacedDigit())
                            .foregroundStyle(Color.textTertiary)
                    }
                    .tag(genre.value)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(L10n.string("\(genre.value), \(genre.songCount) songs"))
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var songsPane: some View {
        if let genre = self.vm.selectedGenre {
            VStack(spacing: 0) {
                HStack {
                    Text(genre)
                        .font(Typography.title)
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    Text(localized: "\(self.vm.genreSongs.count) songs")
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()

                List {
                    ForEach(Array(self.vm.genreSongs.enumerated()), id: \.element.id) { index, song in
                        SubsonicSongRow(
                            song: song,
                            serverID: self.serverID,
                            coverArtProvider: self.coverArtProvider
                        )
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            Task {
                                await self.library.play(
                                    subsonicSongs: self.vm.genreSongs,
                                    serverID: self.serverID,
                                    startingAt: index
                                )
                            }
                        }
                        .onAppear {
                            if index >= self.vm.genreSongs.count - 10, self.vm.hasMoreGenreSongs {
                                Task { await self.vm.loadMoreGenreSongs() }
                            }
                        }
                    }
                    if self.vm.isLoadingGenreSongs {
                        HStack { Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
                .listStyle(.inset)
            }
        } else {
            ContentUnavailableView(
                L10n.string("Select a Genre"),
                systemImage: "tag",
                description: Text(localized: "Pick a genre on the left to browse its songs.")
            )
        }
    }
}
