import Jellyfin
import Observability
import SwiftUI

// MARK: - JellyfinPlaylistsViewModel

/// Drives the per-server Playlists destination (ADR-097). The listing comes in
/// one request, so there is no paging.
@MainActor
public final class JellyfinPlaylistsViewModel: ObservableObject {
    public let serverID: UUID

    @Published public private(set) var playlists: [JellyfinPlaylist] = []
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?

    private let dataSource: any JellyfinBrowseDataSource
    private let log = AppLogger.make(.ui)

    public init(serverID: UUID, dataSource: any JellyfinBrowseDataSource) {
        self.serverID = serverID
        self.dataSource = dataSource
    }

    public func load() async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            self.playlists = try await self.dataSource.playlists(serverID: self.serverID)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.errorMessage = nil
        } catch {
            self.log.error("ui.jellyfin.playlists.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? L10n.string("Could not load playlists from this server.")
        }
    }
}

// MARK: - JellyfinPlaylistsView

public struct JellyfinPlaylistsView: View {
    public let serverID: UUID
    @ObservedObject public var library: LibraryViewModel
    public let coverArtProvider: JellyfinCoverArtProvider?

    @StateObject private var vm: JellyfinPlaylistsViewModel

    public init(
        serverID: UUID,
        library: LibraryViewModel,
        dataSource: any JellyfinBrowseDataSource,
        coverArtProvider: JellyfinCoverArtProvider?
    ) {
        self.serverID = serverID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self._vm = StateObject(wrappedValue: JellyfinPlaylistsViewModel(serverID: serverID, dataSource: dataSource))
    }

    public var body: some View {
        Group {
            if self.vm.playlists.isEmpty, !self.vm.isLoading {
                ContentUnavailableView(
                    L10n.string("No Playlists"),
                    systemImage: "music.note.list",
                    description: Text(localized: "This server hasn't returned any playlists.")
                )
            } else {
                self.list
            }
        }
        .navigationTitle(L10n.string("Playlists"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await self.vm.load() } } label: {
                    Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(self.vm.isLoading)
                .help(L10n.string("Fetches this server's playlists again."))
            }
        }
        .task(id: self.serverID) {
            if self.vm.playlists.isEmpty {
                await self.vm.load()
            }
        }
        .loadErrorAlert(L10n.string("Couldn't load playlists"), message: self.$vm.errorMessage)
    }

    private var list: some View {
        List {
            ForEach(self.vm.playlists) { playlist in
                Button {
                    Task { await self.library.selectDestination(.jellyfinPlaylist(self.serverID, playlist.id)) }
                } label: {
                    HStack(spacing: 10) {
                        JellyfinCoverImage(
                            provider: self.coverArtProvider,
                            serverID: self.serverID,
                            itemID: playlist.coverArtID,
                            tag: playlist.coverArtTag,
                            seed: abs(playlist.id.hashValue),
                            pixelSize: 80
                        )
                        .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name)
                                .font(Typography.subheadline)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(1)
                            if let count = playlist.songCount {
                                Text(L10n.string("\(count) songs"))
                                    .font(Typography.caption)
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    playlist.songCount.map { L10n.string("\(playlist.name), \($0) songs") } ?? playlist.name
                )
                .help(L10n.string("Opens this playlist's songs."))
            }
            if self.vm.isLoading {
                HStack { Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - JellyfinPlaylistDetailViewModel

/// The songs of one playlist, in playlist order, paged.
@MainActor
public final class JellyfinPlaylistDetailViewModel: JellyfinSongListModel {
    public static let pageSize = 100

    public let playlistID: String
    @Published public private(set) var hasMorePages = true
    @Published public private(set) var hasLoaded = false

    private let dataSource: any JellyfinBrowseDataSource

    public init(serverID: UUID, playlistID: String, dataSource: any JellyfinBrowseDataSource, serverName: String = "") {
        self.playlistID = playlistID
        self.dataSource = dataSource
        super.init(serverID: serverID, serverName: serverName)
    }

    public func loadMore() async {
        guard !self.isLoading, self.hasMorePages else { return }
        self.isLoading = true
        defer {
            self.isLoading = false
            self.hasLoaded = true
        }
        do {
            let page = try await self.dataSource.playlistSongs(
                serverID: self.serverID,
                id: self.playlistID,
                startIndex: self.songs.count,
                limit: Self.pageSize
            )
            // The table keys rows by song id and a diffable snapshot refuses a
            // repeated id, so a song that is in the playlist twice shows once.
            var seen = Set(self.songs.map(\.id))
            self.songs.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
            self.hasMorePages = page.items.count == Self.pageSize && page.total.map { self.songs.count < $0 } ?? true
            self.errorMessage = nil
        } catch {
            self.log.error("ui.jellyfin.playlist.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = self.message(for: error, fallback: L10n.string("Could not load this playlist."))
        }
    }
}

// MARK: - JellyfinPlaylistDetailView

public struct JellyfinPlaylistDetailView: View {
    public let serverID: UUID
    public let playlistID: String
    @ObservedObject public var library: LibraryViewModel
    public let coverArtProvider: JellyfinCoverArtProvider?

    @StateObject private var vm: JellyfinPlaylistDetailViewModel
    @ObservedObject private var jellyfin: JellyfinSourceModel

    public init(
        serverID: UUID,
        playlistID: String,
        library: LibraryViewModel,
        dataSource: any JellyfinBrowseDataSource,
        coverArtProvider: JellyfinCoverArtProvider?
    ) {
        self.serverID = serverID
        self.playlistID = playlistID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self.jellyfin = library.jellyfin
        self._vm = StateObject(
            wrappedValue: JellyfinPlaylistDetailViewModel(
                serverID: serverID,
                playlistID: playlistID,
                dataSource: dataSource,
                serverName: library.jellyfin.servers.first { $0.id == serverID }?.name ?? ""
            )
        )
    }

    public var body: some View {
        Group {
            if self.vm.songs.isEmpty, self.vm.hasLoaded, !self.vm.isLoading {
                ContentUnavailableView(
                    L10n.string("Empty Playlist"),
                    systemImage: "music.note.list",
                    description: Text(localized: "This playlist has no songs.")
                )
            } else if self.vm.songs.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                JellyfinSongListTable(
                    model: self.vm,
                    library: self.library,
                    coverArtProvider: self.coverArtProvider,
                    hasMorePages: self.vm.hasMorePages
                ) {
                    Task { await self.vm.loadMore() }
                }
            }
        }
        .navigationTitle(L10n.string("Playlist"))
        .task(id: self.playlistID) {
            if self.vm.songs.isEmpty {
                await self.vm.loadMore()
            }
        }
        .jellyfinServerName(self.jellyfin, serverID: self.serverID) { self.vm.serverName = $0 }
        .loadErrorAlert(L10n.string("Couldn't load playlist"), message: self.$vm.errorMessage)
    }
}
