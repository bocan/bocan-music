import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicAlbumDetailViewModel

/// Loads a single Subsonic album via `getAlbum` and exposes its songs.
@MainActor
public final class SubsonicAlbumDetailViewModel: ObservableObject, SubsonicAnnotationObserving {
    public let serverID: UUID
    public let albumID: String

    @Published public private(set) var album: AlbumID3? {
        didSet { self.rebuildRows() }
    }

    /// The album's songs, in the order the server returned them.
    public var songs: [Song] {
        self.album?.song ?? []
    }

    /// Decorated rows for `SubsonicSongTable`, owned here rather than mapped
    /// in the view's body, so the O(n) decoration runs once per change of the
    /// album, the annotation overrides or the server name instead of once per
    /// re-render (#475).
    @Published private(set) var rows: [SubsonicSongTableRow] = [] {
        didSet { self.rowsVersion &+= 1 }
    }

    /// Moves on every write to `rows` via `didSet`, so no path can forget it;
    /// `SubsonicSongTable` skips its per-row walks while it holds (#455).
    private(set) var rowsVersion = 0

    /// Display name of this server, carried on every row. Set by the view,
    /// which reads it from the sidebar server list; a rename rebuilds the rows.
    public var serverName: String {
        didSet {
            guard self.serverName != oldValue else { return }
            self.rebuildRows()
        }
    }

    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?

    private let dataSource: any SubsonicBrowseDataSource
    /// Held strongly: the coordinator outlives this view model, and its own
    /// reference back to here is weak.
    private let annotations: SubsonicAnnotationCoordinator?
    private let log = AppLogger.make(.ui)

    public init(
        serverID: UUID,
        albumID: String,
        dataSource: any SubsonicBrowseDataSource,
        annotations: SubsonicAnnotationCoordinator? = nil,
        serverName: String = ""
    ) {
        self.serverID = serverID
        self.albumID = albumID
        self.dataSource = dataSource
        self.annotations = annotations
        self.serverName = serverName
        annotations?.addObserver(self)
    }

    // MARK: - Rows

    /// Rebuilds every row from the album's songs and the current overrides.
    private func rebuildRows() {
        let serverID = self.serverID
        let serverName = self.serverName
        let annotations = self.annotations
        self.rows = self.songs.map {
            SubsonicSongTableRow.make(
                song: $0, serverID: serverID, serverName: serverName, annotations: annotations
            )
        }
    }

    /// A star or rating moved: the stored rows are now stale (#475).
    public func annotationOverridesDidChange() {
        self.rebuildRows()
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
                ?? L10n.string("Could not load this album.")
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
                serverID: serverID,
                albumID: albumID,
                dataSource: dataSource,
                annotations: library.subsonicAnnotations,
                serverName: library.subsonicServers.first { $0.id == serverID }?.name ?? ""
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
        .navigationTitle(self.vm.album?.name ?? L10n.string("Album"))
        .task(id: self.albumID) {
            if self.vm.album == nil {
                await self.vm.load()
            }
        }
        // The row owner needs the server's display name, and the sidebar list
        // it comes from may load, or be renamed, after this view appears.
        .onChange(of: self.currentServerName, initial: true) { _, name in
            self.vm.serverName = name
        }
        .loadErrorAlert(L10n.string("Couldn't load album"), message: self.$vm.errorMessage)
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
                    L10n.string("No Songs"),
                    systemImage: "music.note",
                    description: Text(localized: "This album has no songs to display.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                self.songsTable(songs)
            }
        }
    }

    private func songsTable(_ songs: [Song]) -> some View {
        SubsonicSongTable(
            rows: self.vm.rows,
            rowsVersion: self.vm.rowsVersion,
            isLoading: false,
            hasMorePages: false,
            coverArtProvider: self.coverArtProvider,
            showsSource: false,
            nowPlayingRowID: self.nowPlayingRowID,
            actions: self.makeActions(songs)
        )
    }

    /// Row ID of the currently-playing Subsonic stream, so the table can move its
    /// selection onto the playing song (mirrors the local library).
    private var nowPlayingRowID: String? {
        let np = self.library.nowPlaying
        guard let serverID = np.nowPlayingSubsonicServerID,
              let songID = np.nowPlayingSubsonicSongID else { return nil }
        return SubsonicSongTableRow.id(serverID: serverID, songID: songID)
    }

    private func makeActions(_ songs: [Song]) -> SubsonicSongTableActions {
        SubsonicSongTableActions(
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
                self.headerMeta(album: album, songs: songs)
                if !songs.isEmpty {
                    self.playButton(songs: songs)
                }
            }
            Spacer()
        }
    }

    private func headerMeta(album: AlbumID3, songs: [Song]) -> some View {
        HStack(spacing: 8) {
            if let year = album.year {
                Text(String(year))
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
            }
            let count = songs.count
            if count > 0 {
                Text(localized: "\(count) songs")
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
    }

    private func playButton(songs: [Song]) -> some View {
        Button {
            Task {
                await self.library.play(
                    subsonicSongs: songs, serverID: self.serverID, startingAt: 0
                )
            }
        } label: {
            Label(L10n.string("Play"), systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .padding(.top, 6)
    }

    private var currentServerName: String {
        self.library.subsonicServers.first { $0.id == self.serverID }?.name ?? ""
    }

    private static func formatTotalDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
