import Foundation
import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicBookmarksViewModel

/// Drives the per-server Bookmarks destination (Phase 19 step 11).
///
/// Capability-gated by `SubsonicCapabilities.supportsBookmarks`. Each
/// bookmark wraps a `Song`, so double-tapping plays from the bookmarked
/// song (the saved playback position is currently ignored — seeking to
/// bookmarked positions is a future polish step).
@MainActor
public final class SubsonicBookmarksViewModel: ObservableObject {
    public let serverID: UUID

    @Published public private(set) var bookmarks: [Bookmark] = []
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
            self.bookmarks = try await self.dataSource.getBookmarks(serverID: self.serverID)
            self.errorMessage = nil
        } catch {
            self.log.error("subsonic.bookmarks.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? L10n.string("Could not load bookmarks.")
        }
    }

    public var songs: [Song] {
        self.bookmarks.map(\.entry)
    }
}

// MARK: - SubsonicBookmarksView

public struct SubsonicBookmarksView: View {
    public let serverID: UUID
    public let library: LibraryViewModel
    public let coverArtProvider: SubsonicCoverArtProvider?

    @StateObject private var vm: SubsonicBookmarksViewModel

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
            wrappedValue: SubsonicBookmarksViewModel(serverID: serverID, dataSource: dataSource)
        )
    }

    public var body: some View {
        Group {
            if self.vm.bookmarks.isEmpty, !self.vm.isLoading {
                ContentUnavailableView(
                    L10n.string("No Bookmarks"),
                    systemImage: "bookmark",
                    description: Text(localized: "Bookmarks saved on the server appear here.")
                )
            } else {
                self.list
            }
        }
        .navigationTitle(L10n.string("Bookmarks"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await self.vm.load() } } label: {
                    Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(self.vm.isLoading)
            }
        }
        .task(id: self.serverID) {
            if self.vm.bookmarks.isEmpty { await self.vm.load() }
        }
        .alert(
            L10n.string("Couldn't load bookmarks"),
            isPresented: Binding(
                get: { self.vm.errorMessage != nil },
                set: { if !$0 { self.vm.errorMessage = nil } }
            ),
            actions: { Button(L10n.string("OK"), role: .cancel) {} },
            message: { Text(self.vm.errorMessage ?? "") }
        )
    }

    private var list: some View {
        let songs = self.vm.songs
        return List {
            ForEach(Array(self.vm.bookmarks.enumerated()), id: \.element.entry.id) { index, bookmark in
                HStack(spacing: 10) {
                    SubsonicSongRow(
                        song: bookmark.entry,
                        serverID: self.serverID,
                        coverArtProvider: self.coverArtProvider
                    )
                    Text(Self.formatPosition(bookmark.position))
                        .font(Typography.caption.monospacedDigit())
                        .foregroundStyle(Color.textTertiary)
                }
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

    private static func formatPosition(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
