import Jellyfin
import Observability
import SwiftUI

// MARK: - JellyfinAlbumDetailViewModel

/// Loads one Jellyfin album and its songs. The album and its songs are two
/// requests, made together.
@MainActor
public final class JellyfinAlbumDetailViewModel: JellyfinSongListModel {
    public let albumID: String

    @Published public private(set) var album: JellyfinAlbum?

    private let dataSource: any JellyfinBrowseDataSource

    public init(serverID: UUID, albumID: String, dataSource: any JellyfinBrowseDataSource, serverName: String = "") {
        self.albumID = albumID
        self.dataSource = dataSource
        super.init(serverID: serverID, serverName: serverName)
    }

    public func load() async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            async let album = self.dataSource.album(serverID: self.serverID, id: self.albumID)
            async let songs = self.dataSource.albumSongs(serverID: self.serverID, albumID: self.albumID)
            self.album = try await album
            self.songs = try await songs
            self.errorMessage = nil
        } catch {
            self.log.error("ui.jellyfin.album.detail.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = self.message(for: error, fallback: L10n.string("Could not load this album."))
        }
    }

    /// The album's total length in whole seconds, from its songs.
    var totalSeconds: Int {
        Int(self.songs.compactMap(\.durationSeconds).reduce(0, +))
    }
}

// MARK: - JellyfinAlbumDetailView

/// Header for one album (cover, title, artist, year, counts) above the table of
/// its songs. It mirrors the local album page.
public struct JellyfinAlbumDetailView: View {
    public let serverID: UUID
    public let albumID: String
    @ObservedObject public var library: LibraryViewModel
    public let coverArtProvider: JellyfinCoverArtProvider?

    @StateObject private var vm: JellyfinAlbumDetailViewModel
    @ObservedObject private var jellyfin: JellyfinSourceModel

    public init(
        serverID: UUID,
        albumID: String,
        library: LibraryViewModel,
        dataSource: any JellyfinBrowseDataSource,
        coverArtProvider: JellyfinCoverArtProvider?
    ) {
        self.serverID = serverID
        self.albumID = albumID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self.jellyfin = library.jellyfin
        self._vm = StateObject(
            wrappedValue: JellyfinAlbumDetailViewModel(
                serverID: serverID,
                albumID: albumID,
                dataSource: dataSource,
                serverName: library.jellyfin.servers.first { $0.id == serverID }?.name ?? ""
            )
        )
    }

    public var body: some View {
        Group {
            if let album = self.vm.album {
                self.detail(album)
            } else if self.vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    L10n.string("Album Unavailable"),
                    systemImage: "square.stack",
                    description: Text(localized: "This album could not be loaded.")
                )
            }
        }
        .navigationTitle(self.vm.album?.title ?? L10n.string("Album"))
        .task(id: self.albumID) {
            if self.vm.album == nil {
                await self.vm.load()
            }
        }
        .jellyfinServerName(self.jellyfin, serverID: self.serverID) { self.vm.serverName = $0 }
        .loadErrorAlert(L10n.string("Couldn't load album"), message: self.$vm.errorMessage)
    }

    // MARK: Sub-views

    private func detail(_ album: JellyfinAlbum) -> some View {
        VStack(spacing: 0) {
            self.header(album)
                .padding(20)
                .background(Color.bgSecondary)
            Divider()
            if self.vm.songs.isEmpty {
                ContentUnavailableView(
                    L10n.string("No Songs"),
                    systemImage: "music.note",
                    description: Text(localized: "This album has no songs to display.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                JellyfinSongListTable(model: self.vm, library: self.library, coverArtProvider: self.coverArtProvider)
            }
        }
    }

    private func header(_ album: JellyfinAlbum) -> some View {
        HStack(alignment: .top, spacing: 16) {
            JellyfinCoverImage(
                provider: self.coverArtProvider,
                serverID: self.serverID,
                itemID: album.coverArtID,
                tag: album.coverArtTag,
                seed: abs(album.id.hashValue),
                pixelSize: Int(Theme.albumGridMinWidth * 2)
            )
            .frame(width: 120, height: 120)

            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(Typography.largeTitle)
                    .foregroundStyle(Color.textPrimary)
                if let artist = album.artistName, !artist.isEmpty {
                    Text(artist)
                        .font(Typography.subheadline)
                        .foregroundStyle(Color.textSecondary)
                }
                self.headerMeta(album)
                if !self.vm.songs.isEmpty {
                    self.playButton
                }
            }
            Spacer()
        }
    }

    private func headerMeta(_ album: JellyfinAlbum) -> some View {
        HStack(spacing: 8) {
            if let year = album.year {
                Text(String(year))
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
            }
            let count = self.vm.songs.count
            if count > 0 {
                Text(localized: "\(count) songs")
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
            }
            let total = self.vm.totalSeconds
            if total > 0 {
                Text(Self.formatTotalDuration(total))
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    private var playButton: some View {
        Button {
            let songs = self.vm.songs
            let serverID = self.serverID
            Task { await self.library.play(jellyfinSongs: songs, serverID: serverID, startingAt: 0) }
        } label: {
            Label(L10n.string("Play"), systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .padding(.top, 6)
        .help(L10n.string("Replaces the queue with this album and starts playing. Shuffle applies if it is on."))
    }

    static func formatTotalDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
