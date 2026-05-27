import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicAlbumDetailViewModel

/// Loads a single Subsonic album via `getAlbum` and exposes its songs.
@MainActor
public final class SubsonicAlbumDetailViewModel: ObservableObject {
    public let serverID: UUID
    public let albumID: String

    @Published public private(set) var album: AlbumID3?
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?

    private let dataSource: any SubsonicBrowseDataSource
    private let log = AppLogger.make(.ui)

    public init(serverID: UUID, albumID: String, dataSource: any SubsonicBrowseDataSource) {
        self.serverID = serverID
        self.albumID = albumID
        self.dataSource = dataSource
    }

    public func load() async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            self.album = try await self.dataSource.getAlbum(
                serverID: self.serverID, id: self.albumID
            )
            self.errorMessage = nil
        } catch {
            self.log.error("subsonic.album.detail.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Could not load this album."
        }
    }
}

// MARK: - SubsonicAlbumDetailView

/// Header for one Subsonic album (cover, title, artist, year, counts) plus
/// the full track table for that album. Mirrors the local album-detail
/// shape: header on top, then the standard song list below.
public struct SubsonicAlbumDetailView: View {
    public let serverID: UUID
    public let albumID: String
    @ObservedObject public var library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?

    @StateObject private var vm: SubsonicAlbumDetailViewModel
    @Environment(\.subsonicAnnotationCoordinator) private var annotationCoordinator

    public init(
        serverID: UUID,
        albumID: String,
        library: LibraryViewModel,
        dataSource: any SubsonicBrowseDataSource,
        coverArtProvider: SubsonicCoverArtProvider?
    ) {
        self.serverID = serverID
        self.albumID = albumID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self._vm = StateObject(
            wrappedValue: SubsonicAlbumDetailViewModel(
                serverID: serverID, albumID: albumID, dataSource: dataSource
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
                    "Album Unavailable",
                    systemImage: "square.stack",
                    description: Text("This album could not be loaded.")
                )
            }
        }
        .navigationTitle(self.vm.album?.name ?? "Album")
        .task(id: self.albumID) {
            if self.vm.album == nil { await self.vm.load() }
        }
        .alert(
            "Couldn't load album",
            isPresented: Binding(
                get: { self.vm.errorMessage != nil },
                set: { if !$0 { self.vm.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(self.vm.errorMessage ?? "") }
        )
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func detail(_ album: AlbumID3) -> some View {
        let songs = album.song ?? []
        VStack(spacing: 0) {
            self.header(album, songs: songs)
                .padding(20)
                .background(Color.bgSecondary)
            Divider()
            if songs.isEmpty {
                ContentUnavailableView(
                    "No Songs",
                    systemImage: "music.note",
                    description: Text("This album has no songs to display.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let serverName = self.currentServerName
                let rows = songs.map { song in
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
                    isLoading: false,
                    hasMorePages: false,
                    coverArtProvider: self.coverArtProvider,
                    showsSource: false,
                    actions: SubsonicSongTableActions(
                        playNow: { index in
                            let sid = self.serverID
                            Task {
                                await self.library.play(
                                    subsonicSongs: songs, serverID: sid, startingAt: index
                                )
                            }
                        },
                        loadMore: {},
                        toggleStar: { songID in
                            guard let coord = self.annotationCoordinator else { return }
                            let song = songs.first { $0.id == songID }
                            let starred = coord.isStarred(songID: songID, serverStarred: song?.starred)
                            coord.toggleStar(
                                songID: songID,
                                serverID: self.serverID,
                                currentlyStarred: starred
                            )
                        },
                        setRating: { songID, stars in
                            guard let coord = self.annotationCoordinator else { return }
                            let song = songs.first { $0.id == songID }
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
    }

    private func header(_ album: AlbumID3, songs: [Song]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            SubsonicCoverImage(
                provider: self.coverArtProvider,
                serverID: self.serverID,
                entityID: album.coverArt,
                seed: abs(album.id.hashValue),
                pixelSize: Int(Theme.albumGridMinWidth * 2)
            )
            .frame(width: 120, height: 120)

            VStack(alignment: .leading, spacing: 4) {
                Text(album.name)
                    .font(Typography.largeTitle)
                    .foregroundStyle(Color.textPrimary)
                if let artist = album.artist, !artist.isEmpty {
                    Text(artist)
                        .font(Typography.subheadline)
                        .foregroundStyle(Color.textSecondary)
                }
                HStack(spacing: 8) {
                    if let year = album.year {
                        Text(String(year))
                            .font(Typography.caption)
                            .foregroundStyle(Color.textTertiary)
                    }
                    let n = songs.count
                    if n > 0 {
                        Text(n == 1 ? "1 song" : "\(n) songs")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textTertiary)
                    }
                    let totalSeconds = songs.compactMap(\.duration).reduce(0, +)
                    if totalSeconds > 0 {
                        Text(Self.formatTotalDuration(totalSeconds))
                            .font(Typography.caption.monospacedDigit())
                            .foregroundStyle(Color.textTertiary)
                    }
                }

                if !songs.isEmpty {
                    Button {
                        Task {
                            await self.library.play(
                                subsonicSongs: songs, serverID: self.serverID, startingAt: 0
                            )
                        }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 6)
                }
            }
            Spacer()
        }
    }

    private var currentServerName: String {
        self.library.subsonicServers.first(where: { $0.id == self.serverID })?.name ?? ""
    }

    private static func formatTotalDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
