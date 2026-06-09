import Foundation
import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicStarredViewModel

/// Drives the per-server Starred destination (Phase 19 step 11).
///
/// Wraps `getStarred2`, exposing the song subset for playback. Starred
/// artists/albums are surfaced as section counts only; drill-down would
/// reuse the existing artist/album detail flow if/when wired.
@MainActor
public final class SubsonicStarredViewModel: ObservableObject {
    public let serverID: UUID

    @Published public private(set) var songs: [Song] = []
    @Published public private(set) var albumCount = 0
    @Published public private(set) var artistCount = 0
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
            let starred = try await self.dataSource.getStarred2(serverID: self.serverID)
            self.songs = starred.song ?? []
            self.albumCount = starred.album?.count ?? 0
            self.artistCount = starred.artist?.count ?? 0
            self.errorMessage = nil
        } catch {
            self.log.error("subsonic.starred.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? L10n.string("Could not load starred items.")
        }
    }
}

// MARK: - SubsonicStarredView

public struct SubsonicStarredView: View {
    public let serverID: UUID
    public let library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?

    @StateObject private var vm: SubsonicStarredViewModel

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
            wrappedValue: SubsonicStarredViewModel(serverID: serverID, dataSource: dataSource)
        )
    }

    public var body: some View {
        Group {
            if self.vm.songs.isEmpty, !self.vm.isLoading {
                ContentUnavailableView(
                    L10n.string("Nothing Starred"),
                    systemImage: "star",
                    description: Text(localized: "Star a song on the server to see it here.")
                )
            } else {
                self.list
            }
        }
        .navigationTitle(L10n.string("Starred"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await self.vm.load() } } label: {
                    Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(self.vm.isLoading)
            }
        }
        .task(id: self.serverID) {
            if self.vm.songs.isEmpty { await self.vm.load() }
        }
        .alert(
            L10n.string("Couldn't load starred items"),
            isPresented: Binding(
                get: { self.vm.errorMessage != nil },
                set: { if !$0 { self.vm.errorMessage = nil } }
            ),
            actions: { Button(L10n.string("OK"), role: .cancel) {} },
            message: { Text(self.vm.errorMessage ?? "") }
        )
    }

    /// "%lld artists" and "%lld albums" pluralize independently, so the
    /// summary is composed from the two count keys rather than one format.
    private var alsoStarredSummary: String {
        let artists = L10n.string("\(self.vm.artistCount) artists")
        let albums = L10n.string("\(self.vm.albumCount) albums")
        return L10n.string("\(artists) · \(albums) also starred")
    }

    private var list: some View {
        List {
            if self.vm.albumCount > 0 || self.vm.artistCount > 0 {
                Section {
                    Text(self.alsoStarredSummary)
                        .font(Typography.caption)
                        .foregroundStyle(Color.textTertiary)
                }
            }
            Section(L10n.string("Songs")) {
                ForEach(Array(self.vm.songs.enumerated()), id: \.element.id) { index, song in
                    SubsonicSongRow(
                        song: song,
                        serverID: self.serverID,
                        coverArtProvider: self.coverArtProvider
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        Task {
                            await self.library.play(
                                subsonicSongs: self.vm.songs,
                                serverID: self.serverID,
                                startingAt: index
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}
