import Jellyfin
import Observability
import SwiftUI

// MARK: - JellyfinStarredViewModel

/// Drives the per-server Starred destination (ADR-097): the favourite songs, with
/// the number of favourite albums and artists noted above them. Star is a
/// Jellyfin favourite (D3).
@MainActor
public final class JellyfinStarredViewModel: JellyfinSongListModel {
    @Published public private(set) var albumCount = 0
    @Published public private(set) var artistCount = 0

    private let dataSource: any JellyfinBrowseDataSource

    public init(serverID: UUID, dataSource: any JellyfinBrowseDataSource, serverName: String = "") {
        self.dataSource = dataSource
        super.init(serverID: serverID, serverName: serverName)
    }

    public func load() async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            let starred = try await self.dataSource.starred(serverID: self.serverID)
            self.songs = starred.songs
            self.albumCount = starred.albums.count
            self.artistCount = starred.artists.count
            self.errorMessage = nil
        } catch {
            self.log.error("ui.jellyfin.starred.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = self.message(for: error, fallback: L10n.string("Could not load starred items."))
        }
    }
}

// MARK: - JellyfinStarredView

public struct JellyfinStarredView: View {
    public let serverID: UUID
    @ObservedObject public var library: LibraryViewModel
    public let coverArtProvider: JellyfinCoverArtProvider?

    @StateObject private var vm: JellyfinStarredViewModel
    @ObservedObject private var jellyfin: JellyfinSourceModel

    public init(
        serverID: UUID,
        library: LibraryViewModel,
        dataSource: any JellyfinBrowseDataSource,
        coverArtProvider: JellyfinCoverArtProvider?
    ) {
        self.serverID = serverID
        self.library = library
        self.coverArtProvider = coverArtProvider
        self.jellyfin = library.jellyfin
        self._vm = StateObject(
            wrappedValue: JellyfinStarredViewModel(
                serverID: serverID,
                dataSource: dataSource,
                serverName: library.jellyfin.servers.first { $0.id == serverID }?.name ?? ""
            )
        )
    }

    public var body: some View {
        Group {
            if self.vm.songs.isEmpty, !self.vm.isLoading {
                ContentUnavailableView(
                    L10n.string("Nothing Starred"),
                    systemImage: "star",
                    description: Text(localized: "Mark a song as a favourite on the server to see it here.")
                )
            } else {
                self.content
            }
        }
        .navigationTitle(L10n.string("Starred"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await self.vm.load() } } label: {
                    Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(self.vm.isLoading)
                .help(L10n.string("Fetches your starred items from this server again."))
            }
        }
        .task(id: self.serverID) {
            if self.vm.songs.isEmpty {
                await self.vm.load()
            }
        }
        .jellyfinServerName(self.jellyfin, serverID: self.serverID) { self.vm.serverName = $0 }
        .loadErrorAlert(L10n.string("Couldn't load starred items"), message: self.$vm.errorMessage)
    }

    /// "%lld artists" and "%lld albums" pluralize on their own, so the summary is
    /// composed from the two count keys and not from one format.
    private var alsoStarredSummary: String {
        let artists = L10n.string("\(self.vm.artistCount) artists")
        let albums = L10n.string("\(self.vm.albumCount) albums")
        return L10n.string("\(artists) \u{00B7} \(albums) also starred")
    }

    private var content: some View {
        VStack(spacing: 0) {
            if self.vm.albumCount > 0 || self.vm.artistCount > 0 {
                Text(self.alsoStarredSummary)
                    .font(Typography.caption)
                    .foregroundStyle(Color.textTertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            JellyfinSongListTable(model: self.vm, library: self.library, coverArtProvider: self.coverArtProvider)
        }
    }
}
