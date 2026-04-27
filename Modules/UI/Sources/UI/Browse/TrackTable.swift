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
    /// Insert tracks next in the queue.
    public let playNext: ([Track]) -> Void
    /// Append tracks to the end of the queue.
    public let addToQueue: ([Track]) -> Void
    /// Add tracks to an existing playlist by ID.
    public let addToPlaylist: (Int64, [Track]) -> Void
    /// Create a new playlist pre-populated with the selected tracks.
    public let newPlaylistFromSelection: ([Track]) -> Void
    /// Toggle the loved state of a track.
    public let love: (Track) -> Void
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
    /// Delete a track's file from disk and remove it from the library.
    public let deleteFromDisk: (Track) -> Void
    /// Copy track metadata to the clipboard.
    public let copy: ([Track]) -> Void
    /// Set or clear the shuffle-exclusion flag for a track.
    public let toggleShuffle: (Int64, Bool) -> Void
    /// Remove the selected tracks from the current playlist.
    /// `nil` means this view is not inside a playlist — the menu item is hidden.
    public let removeFromPlaylist: (([Track]) -> Void)?
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
    @AppStorage("appearance.rowDensity") private var rowDensity = "regular"

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
        tableView.autosaveName = self.sortable
            ? "bocan.tracksTable.sortable.v2"
            : "bocan.tracksTable.plain.v2"
        tableView.autosaveTableColumns = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .inset
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        tableView.delegate = coordinator
        tableView.doubleAction = #selector(TrackTableCoordinator.doubleClickAction(_:))
        tableView.target = coordinator

        tableView.menuProvider = { [weak coordinator] in
            coordinator?.buildContextMenu() ?? NSMenu()
        }

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
        coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        return scrollView
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

            var snapshot = NSDiffableDataSourceSnapshot<Int, Int64>()
            snapshot.appendSections([0])
            snapshot.appendItems(newIDs)
            let animated = coordinator.hasAppliedInitialSnapshot && !self.rows.isEmpty
            dataSource.apply(snapshot, animatingDifferences: animated)
            coordinator.hasAppliedInitialSnapshot = true
        } else if coordinator.lastNowPlayingID != self.nowPlayingTrackID {
            // 2 — Only now-playing changed: reconfigure just the affected rows.
            coordinator.updateRows(self.rows)
            var snapshot = dataSource.snapshot()
            var toReconfigure: [Int64] = []
            if let old = coordinator.lastNowPlayingID, let oldID = old { toReconfigure.append(oldID) }
            if let new = self.nowPlayingTrackID, let newID = new { toReconfigure.append(newID) }
            let existing = Set(snapshot.itemIdentifiers(inSection: 0))
            let valid = toReconfigure.filter { existing.contains($0) }
            if !valid.isEmpty {
                snapshot.reloadItems(valid)
                dataSource.apply(snapshot, animatingDifferences: false)
            }
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
    }

    // MARK: - Row density

    private var desiredRowHeight: CGFloat {
        switch self.rowDensity {
        case "compact": 22
        case "spacious": 36
        default: 28
        }
    }

    // MARK: - Column spec

    /// Describes a single table column's identity, sizing, and sort binding.
    struct ColSpec {
        /// The `NSUserInterfaceItemIdentifier` used for the column.
        let id: NSUserInterfaceItemIdentifier
        /// The localised header title.
        let title: String
        /// Minimum column width in points.
        let minWidth: CGFloat
        /// Default column width in points.
        let idealWidth: CGFloat
        /// Maximum column width in points.
        let maxWidth: CGFloat
        /// The sort descriptor key string, or `nil` if not sortable.
        let sortKey: String?
        /// Whether the column starts hidden.
        let hidden: Bool
    }

    /// All columns in display order.  Visibility can be toggled via the header menu.
    static let columnSpecs: [ColSpec] = [
        ColSpec(
            id: .trackNumber,
            title: "#",
            minWidth: 28,
            idealWidth: 32,
            maxWidth: 40,
            sortKey: "trackNumber",
            hidden: false
        ),
        ColSpec(
            id: .title,
            title: "Title",
            minWidth: 140,
            idealWidth: 220,
            maxWidth: 2000,
            sortKey: "title",
            hidden: false
        ),
        ColSpec(
            id: .artist,
            title: "Artist",
            minWidth: 100,
            idealWidth: 160,
            maxWidth: 2000,
            sortKey: "artistName",
            hidden: false
        ),
        ColSpec(
            id: .album,
            title: "Album",
            minWidth: 100,
            idealWidth: 160,
            maxWidth: 2000,
            sortKey: "albumName",
            hidden: false
        ),
        ColSpec(
            id: .year,
            title: "Year",
            minWidth: 48,
            idealWidth: 72,
            maxWidth: 120,
            sortKey: "yearText",
            hidden: false
        ),
        ColSpec(
            id: .genre,
            title: "Genre",
            minWidth: 80,
            idealWidth: 120,
            maxWidth: 2000,
            sortKey: "genre",
            hidden: false
        ),
        ColSpec(
            id: .duration,
            title: "Length",
            minWidth: 48,
            idealWidth: 60,
            maxWidth: 72,
            sortKey: "duration",
            hidden: false
        ),
        ColSpec(
            id: .playCount,
            title: "Plays",
            minWidth: 36,
            idealWidth: 48,
            maxWidth: 56,
            sortKey: "playCount",
            hidden: false
        ),
        ColSpec(
            id: .rating,
            title: "Rating",
            minWidth: 52,
            idealWidth: 64,
            maxWidth: 72,
            sortKey: "rating",
            hidden: false
        ),
        ColSpec(
            id: .addedAt,
            title: "Date Added",
            minWidth: 72,
            idealWidth: 88,
            maxWidth: 2000,
            sortKey: "addedAt",
            hidden: false
        ),
        ColSpec(
            id: .fileFormat,
            title: "Codec",
            minWidth: 40,
            idealWidth: 52,
            maxWidth: 64,
            sortKey: "fileFormat",
            hidden: false
        ),
        ColSpec(
            id: .bitrate,
            title: "Bitrate",
            minWidth: 64,
            idealWidth: 80,
            maxWidth: 96,
            sortKey: "bitrate",
            hidden: false
        ),
        ColSpec(
            id: .sampleRate,
            title: "Sample Rate",
            minWidth: 64,
            idealWidth: 80,
            maxWidth: 96,
            sortKey: "sampleRate",
            hidden: true
        ),
        ColSpec(
            id: .shuffleExclude,
            title: "Shuffle Exclude",
            minWidth: 48,
            idealWidth: 56,
            maxWidth: 64,
            sortKey: "shuffleSortKey",
            hidden: true
        ),
    ]
}
