import AppKit
import Library
import Persistence
import SwiftUI

// MARK: - TrackContextMenuActions

/// All callbacks needed to power the track context menu from AppKit.
/// Each closure is called synchronously on the main thread by AppKit;
/// async library calls are wrapped in Task inside the closures.
public struct TrackContextMenuActions {
    /// Play a single track immediately.
    public let playNow: (Track) -> Void
    /// Play a single track immediately, replacing the queue with just that
    /// one track (no surrounding context).  Used by Option+double-click as
    /// an explicit "play this and nothing else" gesture.
    public let playSingle: (Track) -> Void
    /// Play all tracks from the same album as `track`, replacing the queue.
    public let playAlbum: (Track) -> Void
    /// Play all tracks from the same album as `track`, replacing the queue, shuffled.
    public let shuffleAlbum: (Track) -> Void
    /// Play all tracks by the same artist as `track`, replacing the queue.
    public let playArtist: (Track) -> Void
    /// Insert tracks next in the queue.
    public let playNext: ([Track]) -> Void
    /// Append tracks to the end of the queue.
    public let addToQueue: ([Track]) -> Void
    /// Add tracks to an existing playlist by ID.
    public let addToPlaylist: (Int64, [Track]) -> Void
    /// Create a new playlist pre-populated with the selected tracks.
    public let newPlaylistFromSelection: ([Track]) -> Void
    /// Toggle the loved state on the given tracks (all-loved → unlove all; otherwise love all).
    public let love: ([Track]) -> Void
    /// Navigate the library to the track's artist.
    public let goToArtist: (Int64) -> Void
    /// Navigate the library to the track's album.
    public let goToAlbum: (Int64) -> Void
    /// Reveal the track's file in Finder.
    public let showInFinder: (Track) -> Void
    /// Trigger a metadata re-scan for the track's file.
    public let rescanFile: (Track) -> Void
    /// Show the track inspector for the selected tracks.
    public let getInfo: ([Track]) -> Void
    /// Open the acoustic identify-track sheet for a single track.
    public let identify: (Track) -> Void
    /// Remove tracks from the library without deleting files.
    public let removeFromLibrary: ([Track]) -> Void
    /// Delete the selected tracks' files from disk and remove them from the library.
    public let deleteFromDisk: ([Track]) -> Void
    /// Copy track metadata to the clipboard.
    public let copy: ([TrackRow]) -> Void
    /// Set or clear the shuffle-exclusion flag for a track.
    public let toggleShuffle: (Int64, Bool) -> Void
    /// Compute ReplayGain for the selected tracks, replacing any existing values.
    public let computeReplayGain: ([Track]) -> Void
    /// Set a star rating (0–5) on the selected tracks.
    public let rate: ([Track], Int) -> Void
    /// Remove the selected tracks from the current playlist.
    /// `nil` means this view is not inside a playlist — the menu item is hidden.
    public let removeFromPlaylist: (([Track]) -> Void)?
    /// Open the lyrics editor pane for the selected track.
    /// `nil` disables the menu item.
    public let editLyrics: ((Track) -> Void)?
    /// Fetch lyrics from LRClib for the selected track, replacing any existing lyrics.
    /// `nil` means LRClib is not enabled or the feature is not wired — the menu item is hidden.
    public let fetchLyricsFromLRClib: ((Track) -> Void)?
}

// MARK: - TrackTable

/// Wraps `NSTableView` in SwiftUI using diffable data source.
/// Replaces SwiftUI `Table` to avoid gesture-recogniser contention on rows.
public struct TrackTable: NSViewRepresentable {
    /// The AppKit scroll view that hosts the table.
    public typealias NSViewType = NSScrollView
    /// The coordinator type — lives in `TrackTableCoordinator.swift`.
    public typealias Coordinator = TrackTableCoordinator

    let rows: [TrackRow]
    @Binding var selection: Set<Track.ID>
    @Binding var sortOrder: [KeyPathComparator<TrackRow>]
    let nowPlayingTrackID: Track.ID?
    let sortable: Bool
    let playlistNodes: [PlaylistNode]
    let actions: TrackContextMenuActions
    /// Each increment triggers a scroll-to-now-playing in `updateNSView`.
    let scrollRequest: Int
    /// When non-nil the table allows intra-table drag-reorder and calls this
    /// closure (on the main thread) with SwiftUI-style `(source, destination)` indices.
    let onMove: ((IndexSet, Int) -> Void)?
    @AppStorage("appearance.rowDensity") private var rowDensity = "spacious"

    // MARK: NSViewRepresentable

    /// Creates the coordinator that owns the diffable data source.
    public func makeCoordinator() -> TrackTableCoordinator {
        TrackTableCoordinator(parent: self)
    }

    /// Builds the `NSScrollView` + `NSTableView` hierarchy on first use.
    public func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let tableView = ContextMenuTableView()
        tableView.identifier = NSUserInterfaceItemIdentifier(A11y.TracksTable.table)
        tableView.setAccessibilityLabel(L10n.string("Track List"))
        tableView.setAccessibilityRoleDescription(L10n.string("Music track list"))
        tableView.autosaveName = self.sortable
            ? "bocan.tracksTable.sortable.v4"
            : "bocan.tracksTable.plain.v4"
        tableView.autosaveTableColumns = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .inset
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.refusesFirstResponder = false // Ensure Tab key can reach the table.

        // When reorder is enabled, allow move locally and copy externally.
        if self.onMove != nil {
            tableView.setDraggingSourceOperationMask([.move], forLocal: true)
        } else {
            tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        }
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        if self.onMove != nil {
            tableView.registerForDraggedTypes([.string])
        }

        tableView.delegate = coordinator
        tableView.doubleAction = #selector(TrackTableCoordinator.doubleClickAction(_:))
        tableView.target = coordinator
        self.configureCallbacks(for: tableView, coordinator: coordinator)

        Self.addColumns(to: tableView, sortable: self.sortable)
        Self.buildHeaderMenu(for: tableView, coordinator: coordinator)

        // nonisolated(unsafe) lets the cell-provider closure capture the coordinator
        // without triggering Swift 6 concurrency warnings.  Safe because AppKit
        // always calls the cell-provider on the main thread.
        let cellCoord = coordinator
        let dataSource = TrackDiffableDataSource(tableView: tableView) { tv, column, _, itemID in
            MainActor.assumeIsolated {
                cellCoord.cellView(for: column, trackID: itemID, in: tv) ?? NSTableCellView()
            }
        }
        coordinator.dataSource = dataSource
        dataSource.coordinator = coordinator
        dataSource.onMove = self.onMove
        coordinator.tableView = tableView

        return self.makeScrollView(wrapping: tableView)
    }

    private func makeScrollView(wrapping tableView: NSTableView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        return scrollView
    }

    private func configureCallbacks(for tableView: ContextMenuTableView, coordinator: Coordinator) {
        tableView.menuProvider = { [weak coordinator] in
            coordinator?.buildContextMenu() ?? NSMenu()
        }
        tableView.deleteKeyHandler = { [weak coordinator] in
            coordinator?.handleRemoveFromPlaylistKeyDown() ?? false
        }
        tableView.returnKeyHandler = { [weak coordinator] in
            coordinator?.handleReturnKeyDown()
        }
    }

    /// Pushes state changes from SwiftUI into the existing `NSTableView`.
    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        guard let tableView = coordinator.tableView,
              let dataSource = coordinator.dataSource else { return }

        // 1 — Structural change: a different set of track IDs.
        let newIDs = self.rows.compactMap(\.id)
        let oldIDs = coordinator.lastAppliedIDs

        if newIDs != oldIDs {
            coordinator.updateRows(self.rows)
            coordinator.lastAppliedIDs = newIDs

            // NSDiffableDataSourceSnapshot requires unique item identifiers.
            // Guard against duplicate track IDs (e.g. the same track added
            // twice to a playlist) by deduplicating while preserving order.
            var seen = Set<Int64>()
            let uniqueIDs = newIDs.filter { seen.insert($0).inserted }

            var snapshot = NSDiffableDataSourceSnapshot<Int, Int64>()
            snapshot.appendSections([0])
            snapshot.appendItems(uniqueIDs)
            let animated = coordinator.hasAppliedInitialSnapshot && !self.rows.isEmpty
            dataSource.apply(snapshot, animatingDifferences: animated)
            coordinator.hasAppliedInitialSnapshot = true
        } else {
            // 2 — Same ID set: reconfigure rows whose displayed content changed
            // (love toggled, play count bumped, rating, in-place tag edits) and
            // the rows gaining or losing the now-playing highlight.  Without
            // this the NSTableView keeps rendering stale cells until a reload.
            self.reconfigureChangedRows(coordinator: coordinator, dataSource: dataSource)
        }
        coordinator.lastNowPlayingID = self.nowPlayingTrackID

        // 3 — Selection changed externally (e.g. syncSelectionToNowPlaying).
        let expectedIndexes = IndexSet(
            coordinator.rows.enumerated()
                .compactMap { idx, row -> Int? in
                    guard let id = row.id, selection.contains(id) else { return nil }
                    return idx
                }
        )
        if tableView.selectedRowIndexes != expectedIndexes {
            coordinator.isSyncingSelection = true
            tableView.selectRowIndexes(expectedIndexes, byExtendingSelection: false)
            coordinator.isSyncingSelection = false
        }

        // 4 — Sort indicator changed externally (e.g. "Clear Sort" button).
        coordinator.syncSortIfNeeded(sortOrder: self.sortOrder)

        // 5 — Row density changed in Appearance settings.
        // The coordinator's heightOfRow delegate method reads UserDefaults directly;
        // noteHeightOfRows triggers NSTableView to re-query it for every row.
        if coordinator.lastRowDensity != self.rowDensity {
            coordinator.lastRowDensity = self.rowDensity
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< tableView.numberOfRows))
        }

        // 6 — onMove callback changed (e.g. playlist loaded or kind toggled).
        dataSource.onMove = self.onMove

        // 7 — Scroll to the now-playing track when requested.
        self.applyScrollIfNeeded(coordinator: coordinator, tableView: tableView)
    }

    /// Reloads only the rows whose rendered content changed (or whose
    /// now-playing highlight is gained/lost) while the set of track IDs is
    /// unchanged.  `reloadItems` re-runs the cell provider for those identifiers
    /// without disturbing the row order, selection, or scroll position.
    private func reconfigureChangedRows(
        coordinator: TrackTableCoordinator,
        dataSource: TrackDiffableDataSource
    ) {
        let oldRowsByID = coordinator.rowsByID
        var changed: [Int64] = []
        for row in self.rows {
            guard let id = row.id else { continue }
            if let old = oldRowsByID[id], !old.hasSameContent(as: row) {
                changed.append(id)
            }
        }
        // The now-playing highlight depends on `nowPlayingTrackID`, not on row
        // content, so the outgoing and incoming now-playing rows must refresh
        // too — even when their underlying values are identical.
        if coordinator.lastNowPlayingID != self.nowPlayingTrackID {
            if let old = coordinator.lastNowPlayingID, let oldID = old { changed.append(oldID) }
            if let new = self.nowPlayingTrackID, let newID = new { changed.append(newID) }
        }
        coordinator.updateRows(self.rows)
        guard !changed.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        let existing = Set(snapshot.itemIdentifiers(inSection: 0))
        var seen = Set<Int64>()
        let valid = changed.filter { existing.contains($0) && seen.insert($0).inserted }
        guard !valid.isEmpty else { return }
        snapshot.reloadItems(valid)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func applyScrollIfNeeded(coordinator: TrackTableCoordinator, tableView: NSTableView) {
        guard self.scrollRequest != coordinator.lastScrollRequest else { return }
        coordinator.lastScrollRequest = self.scrollRequest
        if let nowID = self.nowPlayingTrackID,
           let idx = coordinator.rows.firstIndex(where: { $0.id == nowID }) {
            tableView.scrollRowToVisible(idx)
        }
    }

    // MARK: - Row density

    private var desiredRowHeight: CGFloat {
        switch self.rowDensity {
        case "compact":
            22

        case "spacious":
            36

        default:
            28
        }
    }
}
