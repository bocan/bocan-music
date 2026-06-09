import Foundation
import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicPlaylistsViewModel

/// Drives the per-server Playlists destination (Phase 19 step 11).
///
/// Subsonic's `getPlaylists` returns the full listing in one shot, so there
/// is no paging. A pull-to-refresh is wired via the toolbar.
@MainActor
public final class SubsonicPlaylistsViewModel: ObservableObject {
    public let serverID: UUID

    @Published public private(set) var playlists: [Playlist] = []
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?

    private let dataSource: any SubsonicBrowseDataSource
    private let log = AppLogger.make(.ui)

    public init(serverID: UUID, dataSource: any SubsonicBrowseDataSource) {
        self.serverID = serverID
        self.dataSource = dataSource
    }

    public func load() async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            self.playlists = try await self.dataSource.getPlaylists(serverID: self.serverID)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.errorMessage = nil
        } catch {
            self.log.error("subsonic.playlists.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? L10n.string("Could not load playlists from this server.")
        }
    }
}

// MARK: - SubsonicPlaylistsView

public struct SubsonicPlaylistsView: View {
    public let serverID: UUID
    public let library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?

    @StateObject private var vm: SubsonicPlaylistsViewModel

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
            wrappedValue: SubsonicPlaylistsViewModel(serverID: serverID, dataSource: dataSource)
        )
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
            }
        }
        .task(id: self.serverID) {
            if self.vm.playlists.isEmpty { await self.vm.load() }
        }
        .alert(
            L10n.string("Couldn't load playlists"),
            isPresented: Binding(
                get: { self.vm.errorMessage != nil },
                set: { if !$0 { self.vm.errorMessage = nil } }
            ),
            actions: { Button(L10n.string("OK"), role: .cancel) {} },
            message: { Text(self.vm.errorMessage ?? "") }
        )
    }

    private var list: some View {
        List {
            ForEach(self.vm.playlists) { playlist in
                Button {
                    self.library.selectedDestination = .subsonicPlaylist(self.serverID, playlist.id)
                } label: {
                    HStack(spacing: 10) {
                        SubsonicCoverImage(
                            provider: self.coverArtProvider,
                            serverID: self.serverID,
                            entityID: playlist.coverArt,
                            seed: abs(playlist.id.hashValue),
                            pixelSize: 80
                        )
                        .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name)
                                .font(Typography.subheadline)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(1)
                            let count = L10n.string("\(playlist.songCount) songs")
                            Text(count)
                                .font(Typography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.string("\(playlist.name), \(playlist.songCount) songs"))
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

// MARK: - SubsonicPlaylistDetailViewModel

@MainActor
public final class SubsonicPlaylistDetailViewModel: ObservableObject {
    public let serverID: UUID
    public let playlistID: String

    @Published public private(set) var playlist: PlaylistWithSongs?
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?

    private let dataSource: any SubsonicBrowseDataSource
    private let log = AppLogger.make(.ui)

    public init(serverID: UUID, playlistID: String, dataSource: any SubsonicBrowseDataSource) {
        self.serverID = serverID
        self.playlistID = playlistID
        self.dataSource = dataSource
    }

    public func load() async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            self.playlist = try await self.dataSource.getPlaylist(
                serverID: self.serverID,
                id: self.playlistID
            )
            self.errorMessage = nil
        } catch {
            self.log.error("subsonic.playlist.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? L10n.string("Could not load this playlist.")
        }
    }
}

// MARK: - SubsonicPlaylistDetailView

public struct SubsonicPlaylistDetailView: View {
    public let serverID: UUID
    public let playlistID: String
    public let library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?

    @StateObject private var vm: SubsonicPlaylistDetailViewModel

    public init(
        serverID: UUID,
        playlistID: String,
        library: LibraryViewModel,
        dataSource: any SubsonicBrowseDataSource,
        coverArtProvider: SubsonicCoverArtProvider?
    ) {
        self.serverID = serverID
        self.playlistID = playlistID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self._vm = StateObject(
            wrappedValue: SubsonicPlaylistDetailViewModel(
                serverID: serverID,
                playlistID: playlistID,
                dataSource: dataSource
            )
        )
    }

    public var body: some View {
        Group {
            if let pl = self.vm.playlist {
                self.detail(pl)
            } else if self.vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    L10n.string("Playlist Unavailable"),
                    systemImage: "music.note.list",
                    description: Text(localized: "This playlist could not be loaded.")
                )
            }
        }
        .navigationTitle(self.vm.playlist?.name ?? L10n.string("Playlist"))
        .task(id: self.playlistID) {
            if self.vm.playlist == nil { await self.vm.load() }
        }
        .alert(
            L10n.string("Couldn't load playlist"),
            isPresented: Binding(
                get: { self.vm.errorMessage != nil },
                set: { if !$0 { self.vm.errorMessage = nil } }
            ),
            actions: { Button(L10n.string("OK"), role: .cancel) {} },
            message: { Text(self.vm.errorMessage ?? "") }
        )
    }

    @ViewBuilder
    private func detail(_ pl: PlaylistWithSongs) -> some View {
        let songs = pl.entry ?? []
        List {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                SubsonicSongRow(
                    song: song,
                    serverID: self.serverID,
                    coverArtProvider: self.coverArtProvider
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    Task {
                        await self.library.play(
                            subsonicSongs: songs,
                            serverID: self.serverID,
                            startingAt: index
                        )
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}
