import Persistence
import SwiftUI

// MARK: - TracksView

/// Full-width table of tracks.
///
/// - Selection is a `Set<Track.ID>` (multi-select with shift-range, ⌘-toggle).
/// - Double-click or `Return` triggers the play action.
/// - `Space` toggles play/pause via the now-playing strip.
/// - Right-click opens the standard context menu.
///
/// Column-header sorting is only enabled when `sortable == true`.
/// With tens of thousands of rows, sorting via header click is an
/// expensive operation that also fights SwiftUI's update cycle, so the
/// full-library "Songs" view disables it and relies on load-time
/// ordering instead.  Filtered contexts (album, artist, genre,
/// composer, smart folder, active search) are small enough that
/// header sort is both useful and performant.
public struct TracksView: View {
    @Bindable public var vm: TracksViewModel
    public var library: LibraryViewModel
    public var title: String?
    public var sortable: Bool
    /// When non-nil, a "Remove from Playlist" item appears at the top of the
    /// destructive section of the track context menu.
    public var removeFromPlaylist: (([Track]) -> Void)?
    /// When non-nil, enables intra-table drag-reorder and calls this closure
    /// on drop with SwiftUI-style `(source, destination)` index sets.
    public var onMove: ((IndexSet, Int) -> Void)?

    /// Observed separately so that changes to `nowPlayingTrackID` / `isPlaying`
    /// invalidate this view (`@Observable` tracking handles property-level granularity).
    var nowPlaying: NowPlayingViewModel

    /// Local sort state.  Owned by the View (not the VM) so that
    /// NSTableView sort-descriptor writes never fire `objectWillChange`
    /// on `TracksViewModel`.  Pushed into the VM via `.onChange` below.
    @State var sortOrder: [KeyPathComparator<TrackRow>] = TracksViewModel.defaultSortOrder

    @EnvironmentObject private var libraryEnv: LibraryViewModel

    public init(
        vm: TracksViewModel,
        library: LibraryViewModel,
        title: String? = nil,
        sortable: Bool = true,
        removeFromPlaylist: (([Track]) -> Void)? = nil,
        onMove: ((IndexSet, Int) -> Void)? = nil
    ) {
        self.vm = vm
        self.library = library
        self.nowPlaying = library.nowPlaying
        self.title = title
        self.sortable = sortable
        self.removeFromPlaylist = removeFromPlaylist
        self.onMove = onMove
    }

    public var body: some View {
        Group {
            if self.vm.isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.vm.rows.isEmpty {
                EmptyState(
                    symbol: "music.note",
                    title: "No Songs",
                    message: "Add a music folder to start building your library.",
                    actionLabel: "Add Music Folder"
                ) {
                    Task { await self.libraryEnv.addFolderByPicker() }
                }
            } else {
                self.trackTable
            }
        }
        .navigationTitle(self.title ?? "Songs")
        .toolbar {
            if self.sortable, self.sortOrder != TracksViewModel.defaultSortOrder {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear Sort") {
                        self.sortOrder = TracksViewModel.defaultSortOrder
                    }
                    .help("Reset to default sort order")
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }
        }
        .onChange(of: self.sortOrder) { _, newOrder in
            self.vm.applySort(newOrder)
        }
        .onAppear {
            // Seed local sort state from the VM (e.g. restored UIStateV1).
            if self.sortOrder != self.vm.sortOrder {
                self.sortOrder = self.vm.sortOrder
            }
            self.syncSelectionToNowPlaying()
        }
        .onChange(of: self.nowPlaying.nowPlayingTrackID) { _, _ in
            self.syncSelectionToNowPlaying()
        }
    }

    // MARK: - Table

    @ViewBuilder
    private var trackTable: some View {
        if self.sortable {
            self.sortableTable
        } else {
            self.plainTable
        }
    }

    func syncSelectionToNowPlaying() {
        guard let id = self.nowPlaying.nowPlayingTrackID else { return }
        guard self.vm.rows.contains(where: { $0.id == id }) else { return }
        if self.vm.selection != [id] {
            self.vm.selection = [id]
        }
    }
}

// MARK: - Remove-from-playlist confirmation

extension TracksView {
    static let suppressRemoveFromPlaylistConfirmKey =
        "io.cloudcauldron.bocan.playlist.removeTrack.suppressConfirm"

    static func shouldConfirmRemoveFromPlaylist(userDefaults: UserDefaults = .standard) -> Bool {
        !userDefaults.bool(forKey: self.suppressRemoveFromPlaylistConfirmKey)
    }

    static func setRemoveFromPlaylistConfirmationSuppressed(
        _ suppressed: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(suppressed, forKey: self.suppressRemoveFromPlaylistConfirmKey)
    }

    @MainActor
    static func confirmRemoveFromPlaylist(
        tracks: [Track],
        remove: @escaping ([Track]) -> Void,
        userDefaults: UserDefaults = .standard
    ) {
        guard !tracks.isEmpty else { return }
        guard self.shouldConfirmRemoveFromPlaylist(userDefaults: userDefaults) else {
            remove(tracks)
            return
        }

        let alert = NSAlert()
        if tracks.count == 1 {
            let title = tracks.first?.title ?? "track"
            alert.messageText = "Remove “\(title)” from this playlist?"
        } else {
            alert.messageText = "Remove \(tracks.count) tracks from this playlist?"
        }
        alert.informativeText = "Tracks stay in your library and in other playlists."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if alert.suppressionButton?.state == .on {
            Self.setRemoveFromPlaylistConfirmationSuppressed(true, userDefaults: userDefaults)
        }

        remove(tracks)
    }
}
