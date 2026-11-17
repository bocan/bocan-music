import Jellyfin
import Observability
import SwiftUI

// MARK: - JellyfinArtistDetailViewModel

/// Loads one Jellyfin artist and its albums, then the songs of each album in
/// parallel, flattened into one list. The albums show as soon as they arrive;
/// the songs land as each album answers.
@MainActor
public final class JellyfinArtistDetailViewModel: JellyfinSongListModel {
    public let artistID: String

    @Published public private(set) var artist: JellyfinArtist?
    @Published public private(set) var albums: [JellyfinAlbum] = []
    @Published public private(set) var isLoadingTracks = false

    private let dataSource: any JellyfinBrowseDataSource

    public init(serverID: UUID, artistID: String, dataSource: any JellyfinBrowseDataSource, serverName: String = "") {
        self.artistID = artistID
        self.dataSource = dataSource
        super.init(serverID: serverID, serverName: serverName)
    }

    public func load() async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            async let artist = self.dataSource.artist(serverID: self.serverID, id: self.artistID)
            async let albums = self.dataSource.artistAlbums(serverID: self.serverID, artistID: self.artistID)
            self.artist = try await artist
            self.albums = try await albums
            self.errorMessage = nil
            Task { await self.loadTracks() }
        } catch {
            self.log.error("ui.jellyfin.artist.detail.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = self.message(for: error, fallback: L10n.string("Could not load this artist."))
        }
    }

    /// Fetches each album's songs in parallel and keeps them as one list, by
    /// album title and then track. An album that fails is skipped and logged.
    private func loadTracks() async {
        guard !self.albums.isEmpty else { return }
        self.isLoadingTracks = true
        defer { self.isLoadingTracks = false }

        let serverID = self.serverID
        let dataSource = self.dataSource
        let log = self.log
        let albumIDs = self.albums.map(\.id)
        let fetched = await withTaskGroup(of: [JellyfinSong].self) { group in
            for id in albumIDs {
                group.addTask {
                    do {
                        return try await dataSource.albumSongs(serverID: serverID, albumID: id)
                    } catch {
                        log.warning(
                            "ui.jellyfin.artist.albumSongs.failed",
                            ["album": id, "error": String(reflecting: error)]
                        )
                        return []
                    }
                }
            }
            var all: [JellyfinSong] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }
        self.songs = Self.sort(fetched)
    }

    static func sort(_ songs: [JellyfinSong]) -> [JellyfinSong] {
        songs.sorted { lhs, rhs in
            let comparison = (lhs.albumTitle ?? "").localizedCaseInsensitiveCompare(rhs.albumTitle ?? "")
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            let lhsDisc = lhs.discNumber ?? 0
            let rhsDisc = rhs.discNumber ?? 0
            if lhsDisc != rhsDisc {
                return lhsDisc < rhsDisc
            }
            let lhsTrack = lhs.trackNumber ?? 0
            let rhsTrack = rhs.trackNumber ?? 0
            if lhsTrack != rhsTrack {
                return lhsTrack < rhsTrack
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

// MARK: - JellyfinArtistDetailView

/// Artist header, the albums grid and one flat song table, like the local artist page.
public struct JellyfinArtistDetailView: View {
    public let serverID: UUID
    public let artistID: String
    @ObservedObject public var library: LibraryViewModel
    public let coverArtProvider: JellyfinCoverArtProvider?

    @StateObject private var vm: JellyfinArtistDetailViewModel
    @ObservedObject private var jellyfin: JellyfinSourceModel
    @ScaledMetric(relativeTo: .body) private var scaledAlbumMinWidth = Theme.albumGridMinWidth

    public init(
        serverID: UUID,
        artistID: String,
        library: LibraryViewModel,
        dataSource: any JellyfinBrowseDataSource,
        coverArtProvider: JellyfinCoverArtProvider?
    ) {
        self.serverID = serverID
        self.artistID = artistID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self.jellyfin = library.jellyfin
        self._vm = StateObject(
            wrappedValue: JellyfinArtistDetailViewModel(
                serverID: serverID,
                artistID: artistID,
                dataSource: dataSource,
                serverName: library.jellyfin.servers.first { $0.id == serverID }?.name ?? ""
            )
        )
    }

    private var albumColumns: [GridItem] {
        [GridItem(.adaptive(minimum: self.scaledAlbumMinWidth), spacing: Theme.albumGridSpacing)]
    }

    public var body: some View {
        Group {
            if let artist = self.vm.artist {
                self.detail(artist)
            } else if self.vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    L10n.string("Artist Unavailable"),
                    systemImage: "music.mic",
                    description: Text(localized: "This artist could not be loaded.")
                )
            }
        }
        .navigationTitle(self.vm.artist?.name ?? L10n.string("Artist"))
        .task(id: self.artistID) {
            if self.vm.artist == nil {
                await self.vm.load()
            }
        }
        .jellyfinServerName(self.jellyfin, serverID: self.serverID) { self.vm.serverName = $0 }
        .loadErrorAlert(L10n.string("Couldn't load artist"), message: self.$vm.errorMessage)
    }

    // MARK: Sub-views

    private func detail(_ artist: JellyfinArtist) -> some View {
        VStack(spacing: 0) {
            self.header(artist)
                .padding(20)
                .background(Color.bgSecondary)
            Divider()

            if !self.vm.albums.isEmpty {
                self.sectionLabel(L10n.string("Albums"), count: self.vm.albums.count)
                ScrollView {
                    LazyVGrid(columns: self.albumColumns, spacing: Theme.albumGridSpacing) {
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
                            .accessibilityHint(L10n.string("Double-tap to open album"))
                        }
                    }
                    .padding(Theme.albumGridSpacing)
                }
                .frame(maxHeight: 260)
                Divider()
            }

            self.sectionLabel(L10n.string("Songs"), count: self.vm.songs.count)
            if self.vm.songs.isEmpty {
                if self.vm.isLoadingTracks {
                    ProgressView(L10n.string("Loading songs\u{2026}"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        L10n.string("No Songs"),
                        systemImage: "music.note",
                        description: Text(localized: "This artist has no songs to display.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                JellyfinSongListTable(model: self.vm, library: self.library, coverArtProvider: self.coverArtProvider)
            }
        }
    }

    private func header(_ artist: JellyfinArtist) -> some View {
        HStack(spacing: 16) {
            JellyfinCoverImage(
                provider: self.coverArtProvider,
                serverID: self.serverID,
                itemID: artist.coverArtID,
                tag: artist.coverArtTag,
                seed: abs(artist.id.hashValue),
                pixelSize: 200
            )
            .frame(width: 96, height: 96)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name)
                    .font(Typography.largeTitle)
                    .foregroundStyle(Color.textPrimary)
                self.headerCounts
            }
            Spacer()
        }
    }

    private var headerCounts: some View {
        HStack(spacing: 8) {
            let albumCount = self.vm.albums.count
            if albumCount > 0 {
                Text(albumCount == 1 ? L10n.string("1 album") : L10n.string("\(albumCount) albums"))
                    .font(Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            let songCount = self.vm.songs.count
            if albumCount > 0, songCount > 0 {
                Text(verbatim: "\u{00B7}")
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
            }
            if songCount > 0 {
                Text(songCount == 1 ? L10n.string("1 song") : L10n.string("\(songCount) songs"))
                    .font(Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            } else if self.vm.isLoadingTracks {
                Text(localized: "loading songs\u{2026}")
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        let label = "\(title) (\(count))"
        return Text(label)
            .font(Typography.title)
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bgSecondary)
    }
}
