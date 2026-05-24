import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicAlbumsView

/// Per-server Albums destination (Phase 19 step 10). Paged grid of albums
/// fetched alphabetically via `getAlbumList2`.
public struct SubsonicAlbumsView: View {
    public let serverID: UUID
    public let library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?
    public let title: String

    @StateObject private var vm: SubsonicAlbumsViewModel
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
                listType: listType
            )
        )
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: self.minWidth), spacing: Theme.albumGridSpacing)]
    }

    public var body: some View {
        Group {
            if self.vm.albums.isEmpty, !self.vm.isLoading {
                ContentUnavailableView(
                    "No Albums",
                    systemImage: "square.grid.2x2",
                    description: Text("This server hasn't returned any albums yet.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: self.columns, spacing: Theme.albumGridSpacing) {
                        ForEach(self.vm.albums) { album in
                            SubsonicAlbumCell(
                                album: album,
                                serverID: self.serverID,
                                coverArtProvider: self.coverArtProvider
                            )
                            .onAppear {
                                if album.id == self.vm.albums.last?.id, self.vm.hasMorePages {
                                    Task { await self.vm.loadMore() }
                                }
                            }
                        }
                    }
                    .padding(Theme.albumGridSpacing)

                    if self.vm.isLoading {
                        ProgressView()
                            .padding(.vertical, 12)
                    }
                }
            }
        }
        .navigationTitle(self.title)
        .task(id: self.serverID) {
            if self.vm.albums.isEmpty { await self.vm.load() }
        }
        .alert(
            "Couldn't load albums",
            isPresented: Binding(
                get: { self.vm.errorMessage != nil },
                set: { if !$0 { self.vm.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(self.vm.errorMessage ?? "") }
        )
    }
}

// MARK: - SubsonicAlbumCell

private struct SubsonicAlbumCell: View {
    let album: AlbumID3
    let serverID: UUID
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

            Text(self.album.name)
                .font(Typography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            Text(self.album.artist ?? "Various Artists")
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)

            let yearString = self.album.year.map { String($0) }
            let countString = "\(self.album.songCount) \(self.album.songCount == 1 ? "song" : "songs")"
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
            [self.album.name, self.album.artist, self.album.year.map(String.init)]
                .compactMap(\.self)
                .joined(separator: ", ")
        )
    }
}
