import AppKit
import Foundation
import Jellyfin
import SwiftUI

typealias JellyfinSongTableUpdatePlan = TableUpdatePlan<String, String>

// MARK: - Actions bag

/// Closures wired from a Jellyfin browse view into the table and its coordinator.
struct JellyfinSongTableActions {
    /// Play the list starting at `index`.
    let playNow: (Int) -> Void
    /// Ask for the next page of songs.
    let loadMore: () -> Void
}

// MARK: - NSViewRepresentable

/// `NSTableView`-backed song list for a Jellyfin server, the twin of
/// `SubsonicSongTable`. It keeps the behaviour of the Subsonic one, including the
/// version-gated updates (#455), in-place row reloads (#476), the autosaved column
/// order and width, and the header menu for column visibility.
///
/// The `showsSource` flag adds a "Source" column for aggregated search results.
struct JellyfinSongTable: NSViewRepresentable {
    let rows: [JellyfinSongTableRow]
    /// The owner's counter for `rows` (#455): `updateNSView` walks the rows only
    /// when this moved since the last apply. Deliberately has no default: a
    /// caller that left it out would render its first rows and then never react
    /// to another change (#454).
    let rowsVersion: Int
    let isLoading: Bool
    let hasMorePages: Bool
    let coverArtProvider: JellyfinCoverArtProvider?
    let showsSource: Bool
    /// Row ID of the song that is playing, or `nil`. The table moves its
    /// selection onto that row when it changes. Playback arrives in slice 5.
    var nowPlayingRowID: String?
    let actions: JellyfinSongTableActions

    typealias NSViewType = NSScrollView

    func makeCoordinator() -> JellyfinSongTableCoordinator {
        JellyfinSongTableCoordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let tableView = NSTableView()
        tableView.setAccessibilityIdentifier(A11y.Jellyfin.songTable)
        tableView.style = .fullWidth
        tableView.rowSizeStyle = .custom
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let autosaveName = Self.autosaveName
        Self.addColumns(to: tableView, includingSource: self.showsSource, autosaveName: autosaveName)
        // Arm autosave only after the columns exist; setting `autosaveName`
        // restores the order and widths onto the current columns (#369).
        tableView.autosaveTableColumns = true
        tableView.autosaveName = autosaveName
        Self.buildHeaderMenu(for: tableView, coordinator: context.coordinator)

        let dataSource = JellyfinSongDiffableDataSource(tableView: tableView) { tv, col, _, id in
            context.coordinator.cellView(for: col, songID: id, in: tv) ?? NSTableCellView()
        }
        dataSource.coordinator = context.coordinator
        tableView.dataSource = dataSource
        tableView.delegate = context.coordinator
        // Streamed rows can be dragged out (into the Up Next queue in slice 5).
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)

        tableView.target = context.coordinator
        tableView.doubleAction = #selector(JellyfinSongTableCoordinator.doubleClickAction(_:))

        let contextMenu = NSMenu()
        contextMenu.delegate = context.coordinator
        tableView.menu = contextMenu

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.dataSource = dataSource

        // Watch the scroll position to trigger pagination.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(JellyfinSongTableCoordinator.scrollViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let dataSource = coordinator.dataSource else { return }

        // Decide what moved since the last apply (#455). The rows version gates
        // every per-row walk, so a parent re-render with unchanged rows rebuilds
        // neither the cell-lookup dictionary nor the ID sets. The table keeps its
        // own row order (a header-click sort rewrites it).
        let plan = JellyfinSongTableUpdatePlan.make(
            rowsVersion: self.rowsVersion,
            ids: { self.rows.map(\.id) },
            nowPlayingID: nil,
            selection: [],
            applied: coordinator.applied
        )
        switch plan.rowsWork {
        case .unchanged:
            break

        case .reconfigure:
            // Same rows, new content: refresh the lookup the cells read from,
            // then reload the rows whose rendered values actually moved (#476).
            let changed = Self.changedRowIDs(from: coordinator.rowsByID, to: self.rows)
            coordinator.updateRows(self.rows)
            Self.reload(rows: changed, dataSource: dataSource, tableView: coordinator.tableView)

        case .structural:
            coordinator.updateRows(self.rows)
            // Keep the order of songs already loaded; append new songs at the
            // end. Apply a snapshot only when that changed the list.
            let newIDSet = Set(plan.ids ?? [])
            let currentIDSet = Set(coordinator.applied.ids)
            let keepIDs = coordinator.applied.ids.filter { newIDSet.contains($0) }
            let addIDs = self.rows.filter { !currentIDSet.contains($0.id) }.map(\.id)
            let orderedIDs = keepIDs + addIDs
            if orderedIDs != coordinator.applied.ids {
                var snap = NSDiffableDataSourceSnapshot<Int, String>()
                snap.appendSections([0])
                snap.appendItems(orderedIDs)
                dataSource.apply(snap, animatingDifferences: coordinator.hasAppliedInitialSnapshot)
                coordinator.hasAppliedInitialSnapshot = true
            }
            coordinator.applied.ids = orderedIDs
        }
        coordinator.applied.rowsVersion = self.rowsVersion

        coordinator.syncSelectionToNowPlaying(self.nowPlayingRowID)
    }

    // MARK: Reconfigure

    /// IDs of the rows whose rendered values differ from the ones the
    /// coordinator still holds. A row the coordinator does not know is not a
    /// content change: the structural path owns new rows.
    static func changedRowIDs(
        from oldRowsByID: [String: JellyfinSongTableRow],
        to rows: [JellyfinSongTableRow]
    ) -> [String] {
        rows.compactMap { row in
            guard let old = oldRowsByID[row.id], !old.hasSameContent(as: row) else { return nil }
            return row.id
        }
    }

    /// Reloads the given rows in place, ignoring IDs the snapshot does not hold
    /// and duplicates. The selection goes back on afterwards, since an applied
    /// reload drops it.
    private static func reload(
        rows changed: [String],
        dataSource: JellyfinSongDiffableDataSource,
        tableView: NSTableView?
    ) {
        guard !changed.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        let existing = Set(snapshot.itemIdentifiers(inSection: 0))
        var seen = Set<String>()
        let valid = changed.filter { existing.contains($0) && seen.insert($0).inserted }
        guard !valid.isEmpty else { return }
        snapshot.reloadItems(valid)
        applyPreservingSelection(snapshot, to: dataSource, in: tableView)
    }

    // MARK: Column definitions

    static let autosaveName = "bocan.jellyfinSongsTable.v1"

    private struct ColDef {
        let rawID: String
        let title: String
        let min: CGFloat
        let ideal: CGFloat
        let max: CGFloat
        let sortKey: String?
        var hidden = false
    }

    private static let colDefs: [ColDef] = [
        ColDef(rawID: "art", title: L10n.string("Art"), min: 18, ideal: 32, max: 44, sortKey: nil),
        ColDef(rawID: "title", title: L10n.string("Title"), min: 140, ideal: 220, max: 2000, sortKey: "title"),
        ColDef(rawID: "artist", title: L10n.string("Artist"), min: 80, ideal: 160, max: 2000, sortKey: "artist"),
        ColDef(rawID: "album", title: L10n.string("Album"), min: 80, ideal: 160, max: 2000, sortKey: "album"),
        ColDef(rawID: "year", title: L10n.string("Year"), min: 40, ideal: 56, max: 80, sortKey: "year"),
        ColDef(rawID: "genre", title: L10n.string("Genre"), min: 60, ideal: 120, max: 2000, sortKey: "genre"),
        ColDef(rawID: "duration", title: L10n.string("Length"), min: 48, ideal: 60, max: 72, sortKey: "duration"),
        ColDef(rawID: "trackNum", title: L10n.string("Track"), min: 28, ideal: 40, max: 56, sortKey: "trackNum"),
        ColDef(rawID: "bitrate", title: L10n.string("Bitrate"), min: 56, ideal: 72, max: 96, sortKey: "bitrate", hidden: true),
        ColDef(rawID: "starred", title: "\u{2605}", min: 24, ideal: 32, max: 40, sortKey: "starred"),
    ]

    /// Appended only when `showsSource` is `true`: the table shows aggregated
    /// search results and the user needs to tell the servers apart.
    private static let sourceColDef = ColDef(
        rawID: "source", title: L10n.string("Source"), min: 80, ideal: 120, max: 240, sortKey: "source"
    )

    private static func addColumns(to tableView: NSTableView, includingSource: Bool, autosaveName: String) {
        var defs = self.colDefs
        if includingSource {
            defs.append(self.sourceColDef)
        }
        for def in defs {
            let colID = NSUserInterfaceItemIdentifier("jcol.\(def.rawID)")
            let col = NSTableColumn(identifier: colID)
            col.title = def.title
            col.headerCell.title = def.title
            col.headerCell.setAccessibilityLabel(def.title)
            col.minWidth = def.min
            col.width = def.ideal
            col.maxWidth = def.max
            if let key = def.sortKey {
                col.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            }
            // Restore the saved visibility, falling back to the default.
            let visKey = "bocan.col.hidden.\(autosaveName).jcol.\(def.rawID)"
            col.isHidden = UserDefaults.standard.object(forKey: visKey) != nil
                ? UserDefaults.standard.bool(forKey: visKey)
                : def.hidden
            tableView.addTableColumn(col)
        }
    }

    private static func buildHeaderMenu(for tableView: NSTableView, coordinator: JellyfinSongTableCoordinator) {
        let menu = NSMenu()
        for col in tableView.tableColumns {
            let item = NSMenuItem(
                title: col.title,
                action: #selector(JellyfinSongTableCoordinator.toggleColumnVisibility(_:)),
                keyEquivalent: ""
            )
            item.representedObject = col
            item.state = col.isHidden ? .off : .on
            item.target = coordinator
            menu.addItem(item)
        }
        tableView.headerView?.menu = menu
    }
}

// MARK: - Diffable data source

@MainActor
final class JellyfinSongDiffableDataSource: NSTableViewDiffableDataSource<Int, String> {
    weak var coordinator: JellyfinSongTableCoordinator?

    @objc func tableView(_ tableView: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
        MainActor.assumeIsolated {
            self.coordinator?.handleSortChanged(in: tableView)
        }
    }

    /// Lets a streamed song be dragged out by writing a `JellyfinSongDragPayload` for the row.
    @objc func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        // Resolve the Sendable payload on the main actor, then build the AppKit
        // item outside the isolation boundary: `NSPasteboardWriting` is not Sendable.
        let payload: JellyfinSongDragPayload? = MainActor.assumeIsolated {
            guard let id = itemIdentifier(forRow: row) else { return nil }
            return self.coordinator?.dragPayload(forID: id)
        }
        guard let payload else { return nil }
        return JellyfinSongDrag.pasteboardItem(for: [payload])
    }
}
