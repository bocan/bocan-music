import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicArtistDetailViewModel

/// Loads a single Subsonic artist via `getArtist`, then fans out
/// `getAlbum` calls in parallel to flatten the artist's songs into a
/// single list. Albums are available immediately; tracks land as each
/// `getAlbum` resolves.
@MainActor
public final class SubsonicArtistDetailViewModel: ObservableObject {
    public let serverID: UUID
    public let artistID: String

    @Published public private(set) var artist: ArtistID3?
    @Published public private(set) var albums: [AlbumID3] = []
    @Published public private(set) var tracks: [Song] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var isLoadingTracks = false
    @Published public var errorMessage: String?

    private let dataSource: any SubsonicBrowseDataSource
    private let log = AppLogger.make(.ui)

    public init(serverID: UUID, artistID: String, dataSource: any SubsonicBrowseDataSource) {
        self.serverID = serverID
        self.artistID = artistID
        self.dataSource = dataSource
    }

    public func load() async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            let artist = try await self.dataSource.getArtist(
                serverID: self.serverID, id: self.artistID
            )
            self.artist = artist
            self.albums = artist.album ?? []
            self.errorMessage = nil
            Task { await self.loadTracks() }
        } catch {
            self.log.error("subsonic.artist.detail.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? L10n.string("Could not load this artist.")
        }
    }

    /// Fetches each album's songs in parallel and stores them as a flat
    /// list. Sort: by album name (case-insensitive), then track number.
    private func loadTracks() async {
        guard !self.albums.isEmpty else { return }
        self.isLoadingTracks = true
        defer { self.isLoadingTracks = false }

        let serverID = self.serverID
        let dataSource = self.dataSource
        let albumIDs = self.albums.map(\.id)

        let fetched = await withTaskGroup(of: [Song].self) { group in
            for id in albumIDs {
                group.addTask {
                    do {
                        let album = try await dataSource.getAlbum(serverID: serverID, id: id)
                        return album.song ?? []
                    } catch {
                        return []
                    }
                }
            }
            var all: [Song] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }
        self.tracks = Self.sort(fetched)
    }

    private static func sort(_ songs: [Song]) -> [Song] {
        songs.sorted { lhs, rhs in
            let la = lhs.album ?? ""
            let ra = rhs.album ?? ""
            let cmp = la.localizedCaseInsensitiveCompare(ra)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            let lt = lhs.track ?? 0
            let rt = rhs.track ?? 0
            if lt != rt { return lt < rt }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

// MARK: - SubsonicArtistDetailView

/// Artist header + albums grid + flat song table for one Subsonic artist.
/// Mirrors the local `ArtistDetailView` layout. Albums render as soon as
/// `getArtist` returns; the song table populates as each album's songs
/// finish loading in parallel.
public struct SubsonicArtistDetailView: View {
    public let serverID: UUID
    public let artistID: String
    @ObservedObject public var library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?

    @StateObject private var vm: SubsonicArtistDetailViewModel
    @Environment(\.subsonicAnnotationCoordinator) private var annotationCoordinator
    @ScaledMetric(relativeTo: .body) private var scaledAlbumMinWidth = Theme.albumGridMinWidth

    public init(
        serverID: UUID,
        artistID: String,
        library: LibraryViewModel,
        dataSource: any SubsonicBrowseDataSource,
        coverArtProvider: SubsonicCoverArtProvider?
    ) {
        self.serverID = serverID
        self.artistID = artistID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self._vm = StateObject(
            wrappedValue: SubsonicArtistDetailViewModel(
                serverID: serverID, artistID: artistID, dataSource: dataSource
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
            if self.vm.artist == nil { await self.vm.load() }
        }
        .alert(
            L10n.string("Couldn't load artist"),
            isPresented: Binding(
                get: { self.vm.errorMessage != nil },
                set: { if !$0 { self.vm.errorMessage = nil } }
            ),
            actions: { Button(L10n.string("OK"), role: .cancel) {} },
            message: { Text(self.vm.errorMessage ?? "") }
        )
    }

    // MARK: - Sub-views

    private func detail(_ artist: ArtistID3) -> some View {
        VStack(spacing: 0) {
            self.header(artist)
                .padding(20)
                .background(Color.bgSecondary)
            Divider()

            if !self.vm.albums.isEmpty {
                self.sectionLabel(L10n.string("Albums"), count: self.vm.albums.count)
                ScrollView {
                    LazyVGrid(columns: self.albumColumns, spacing: Theme.albumGridSpacing) {
                        ForEach(self.vm.albums, id: \.id) { album in
                            self.albumCell(album)
                        }
                    }
                    .padding(Theme.albumGridSpacing)
                }
                .frame(maxHeight: 260)
                Divider()
            }

            self.sectionLabel(L10n.string("Songs"), count: self.vm.tracks.count)
            if self.vm.tracks.isEmpty {
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
                self.songsTable
            }
        }
    }

    private func header(_ artist: ArtistID3) -> some View {
        HStack(spacing: 16) {
            SubsonicCoverImage(
                provider: self.coverArtProvider,
                serverID: self.serverID,
                entityID: artist.coverArt,
                seed: abs(artist.id.hashValue),
                pixelSize: 200
            )
            .frame(width: 96, height: 96)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name)
                    .font(Typography.largeTitle)
                    .foregroundStyle(Color.textPrimary)

                HStack(spacing: 8) {
                    let albumCount = self.vm.albums.count
                    if albumCount > 0 {
                        Text(albumCount == 1 ? "1 album" : "\(albumCount) albums")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                    let trackCount = self.vm.tracks.count
                    if albumCount > 0, trackCount > 0 {
                        Text(verbatim: "\u{00B7}")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textTertiary)
                    }
                    if trackCount > 0 {
                        Text(trackCount == 1 ? "1 song" : "\(trackCount) songs")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textSecondary)
                    } else if self.vm.isLoadingTracks {
                        Text(localized: "loading songs\u{2026}")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textTertiary)
                    }
                }
            }
            Spacer()
        }
    }

    private func sectionLabel(_ title: String, count: Int? = nil) -> some View {
        let label = count.map { "\(title) (\($0))" } ?? title
        return Text(label)
            .font(Typography.title)
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bgSecondary)
    }

    private func albumCell(_ album: AlbumID3) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SubsonicCoverImage(
                provider: self.coverArtProvider,
                serverID: self.serverID,
                entityID: album.coverArt,
                seed: abs(album.id.hashValue),
                pixelSize: Int(Theme.albumGridMinWidth * 2)
            )
            .frame(maxWidth: .infinity)

            Text(album.name)
                .font(Typography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            let yearString = album.year.map { String($0) }
            let countString = L10n.string("\(album.songCount) songs")
            let subtitle = [yearString, countString].compactMap(\.self).joined(separator: " · ")
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            let sid = self.serverID
            let aid = album.id
            Task { await self.library.selectDestination(.subsonicAlbum(sid, aid)) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [album.name, album.year.map(String.init)]
                .compactMap(\.self)
                .joined(separator: ", ")
        )
        .accessibilityHint(L10n.string("Double-tap to open album"))
    }

    @ViewBuilder
    private var songsTable: some View {
        let songs = self.vm.tracks
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
            isLoading: self.vm.isLoadingTracks,
            hasMorePages: false,
            coverArtProvider: self.coverArtProvider,
            showsSource: false,
            nowPlayingRowID: self.nowPlayingRowID,
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

    private var currentServerName: String {
        self.library.subsonicServers.first { $0.id == self.serverID }?.name ?? ""
    }

    /// Row ID of the currently-playing Subsonic stream, so the table can move its
    /// selection onto the playing song (mirrors the local library).
    private var nowPlayingRowID: String? {
        let np = self.library.nowPlaying
        guard let serverID = np.nowPlayingSubsonicServerID,
              let songID = np.nowPlayingSubsonicSongID else { return nil }
        return SubsonicSongTableRow.id(serverID: serverID, songID: songID)
    }
}
