import AppKit
import Foundation
import Persistence
import SwiftUI

// MARK: - Actions bag

/// Closures wired from `HistoryView` into the table and its coordinator.
/// The song actions take row keys; the view resolves a key to its song,
/// because the song is read fresh at action time rather than carried in
/// the row. The reveal reads the row itself, so it never waits on a read.
struct HistoryTableActions {
    let playNow: (PlayHistoryRow.Key) -> Void
    let playNext: ([PlayHistoryRow.Key]) -> Void
    let addToQueue: ([PlayHistoryRow.Key]) -> Void
    let goToArtist: (Int64) -> Void
    let goToAlbum: (Int64) -> Void
    let showInFinder: (PlayHistoryRow.Key) -> Void
    let getInfo: ([PlayHistoryRow.Key]) -> Void
    /// The table is near its end: widen the window.
    let loadMore: () -> Void
}

// MARK: - NSViewRepresentable

/// The listens table (ADR-094): a third AppKit `NSTableView`, keyed by the
/// listen (source plus that table's row id).
///
/// Not `TrackTable`, and the reason is structural: that table deduplicates
/// row ids because a diffable snapshot needs them unique, and a history is
/// exactly a list where one song appears many times. Keying by the listen
/// makes every row unique with no workaround. Patterned on
/// `SubsonicSongTable`, including its scroll-driven paging.
struct HistoryTable: NSViewRepresentable {
    let rows: [PlayHistoryRow]
    /// The view model's counter for `rows` (#450, #455). Deliberately has no
    /// default: a caller that left it out would render its first rows and
    /// then never react to another change (#454).
    let rowsVersion: Int
    /// `true` while the window may have older rows past its end.
    let hasMore: Bool
    let isLoading: Bool
    let actions: HistoryTableActions

    typealias NSViewType = NSScrollView

    func makeCoordinator() -> HistoryTableCoordinator {
        HistoryTableCoordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let tableView = NSTableView()
        tableView.setAccessibilityIdentifier(A11y.History.table)
        tableView.setAccessibilityLabel(L10n.string("Play history"))
        tableView.style = .fullWidth
        tableView.rowSizeStyle = .custom
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let autosaveName = "bocan.historyTable.v1"
        Self.addColumns(to: tableView, autosaveName: autosaveName)
        // Arm autosave only after the columns exist; setting `autosaveName`
        // triggers the order/width restore onto the current columns (#369).
        tableView.autosaveTableColumns = true
        tableView.autosaveName = autosaveName
        Self.buildHeaderMenu(for: tableView, coordinator: context.coordinator)

        let dataSource = HistoryDiffableDataSource(tableView: tableView) { tv, col, _, key in
            context.coordinator.cellView(for: col, key: key, in: tv) ?? NSTableCellView()
        }
        dataSource.coordinator = context.coordinator
        tableView.dataSource = dataSource
        tableView.delegate = context.coordinator

        tableView.target = context.coordinator
        tableView.doubleAction = #selector(HistoryTableCoordinator.doubleClickAction(_:))

        let contextMenu = NSMenu()
        contextMenu.delegate = context.coordinator
        tableView.menu = contextMenu

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.dataSource = dataSource

        // Widen the window as the user nears the end of it.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(HistoryTableCoordinator.scrollViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let dataSource = coordinator.dataSource else { return }

        // Decide what moved since the last apply (#455). The rows version
        // gates every per-row walk. No highlight and no selection input: a
        // song can be many rows here, so a now-playing highlight would not
        // pick one, and the table owns its own selection.
        let plan = HistoryTableUpdatePlan.make(
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
            // Same listens, new text (a title edited elsewhere): refresh the
            // dictionary the cells read from, then reload only what moved.
            let changed = Self.changedRowIDs(from: coordinator.rowsByID, to: self.rows)
            coordinator.updateRows(self.rows)
            Self.reload(rows: changed, dataSource: dataSource, tableView: coordinator.tableView)

        case .structural:
            // A listen arrived, the window widened, or the filter changed.
            // Apply the rows in the view model's order (newest first),
            // flipped if the header sort is ascending. The diffable apply
            // keeps the selection on rows that survive, so a play inserting
            // at the top moves nothing else (#543).
            coordinator.updateRows(self.rows)
            let ordered = coordinator.orderedIDs()
            var snapshot = NSDiffableDataSourceSnapshot<Int, PlayHistoryRow.Key>()
            snapshot.appendSections([0])
            snapshot.appendItems(ordered)
            dataSource.apply(snapshot, animatingDifferences: coordinator.hasAppliedInitialSnapshot)
            coordinator.hasAppliedInitialSnapshot = true
            coordinator.applied.ids = ordered
        }
        coordinator.applied.rowsVersion = self.rowsVersion
    }

    // MARK: Reconfigure

    /// Keys of the rows whose values differ from what the coordinator holds.
    /// A row the coordinator does not know is not a content change: the
    /// structural path owns new rows.
    static func changedRowIDs(
        from oldRowsByID: [PlayHistoryRow.Key: PlayHistoryRow],
        to rows: [PlayHistoryRow]
    ) -> [PlayHistoryRow.Key] {
        rows.compactMap { row in
            guard let old = oldRowsByID[row.id], old != row else { return nil }
            return row.id
        }
    }

    /// Reloads the given rows in place, ignoring keys the snapshot does not
    /// hold. The selection goes back on afterwards, since a reload drops it.
    private static func reload(
        rows changed: [PlayHistoryRow.Key],
        dataSource: HistoryDiffableDataSource,
        tableView: NSTableView?
    ) {
        guard !changed.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        let existing = Set(snapshot.itemIdentifiers(inSection: 0))
        var seen = Set<PlayHistoryRow.Key>()
        let valid = changed.filter { existing.contains($0) && seen.insert($0).inserted }
        guard !valid.isEmpty else { return }
        snapshot.reloadItems(valid)
        applyPreservingSelection(snapshot, to: dataSource, in: tableView)
    }

    // MARK: Column definitions

    struct ColDef {
        let rawID: String
        let title: String
        let min: CGFloat
        let ideal: CGFloat
        let max: CGFloat
        /// Only the Played column sorts in this slice: the natural order of a
        /// history is time, and the other columns would need a secondary key.
        let sortKey: String?
    }

    static let colDefs: [ColDef] = [
        ColDef(rawID: "playedAt", title: L10n.string("Played"), min: 150, ideal: 180, max: 260, sortKey: "playedAt"),
        ColDef(rawID: "title", title: L10n.string("Title"), min: 140, ideal: 240, max: 2000, sortKey: nil),
        ColDef(rawID: "artist", title: L10n.string("Artist"), min: 80, ideal: 170, max: 2000, sortKey: nil),
        ColDef(rawID: "album", title: L10n.string("Album"), min: 80, ideal: 170, max: 2000, sortKey: nil),
        ColDef(rawID: "source", title: L10n.string("Source"), min: 60, ideal: 80, max: 120, sortKey: nil),
    ]

    static func columnID(_ rawID: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("hcol.\(rawID)")
    }

    private static func addColumns(to tableView: NSTableView, autosaveName: String) {
        for def in self.colDefs {
            let col = NSTableColumn(identifier: Self.columnID(def.rawID))
            col.title = def.title
            col.headerCell.title = def.title
            col.headerCell.setAccessibilityLabel(def.title)
            col.minWidth = def.min
            col.width = def.ideal
            col.maxWidth = def.max
            if let key = def.sortKey {
                // Newest first is the default; a click on the header flips it.
                col.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: false)
            }
            let visKey = "bocan.col.hidden.\(autosaveName).hcol.\(def.rawID)"
            if UserDefaults.standard.object(forKey: visKey) != nil {
                col.isHidden = UserDefaults.standard.bool(forKey: visKey)
            }
            tableView.addTableColumn(col)
        }
    }

    private static func buildHeaderMenu(for tableView: NSTableView, coordinator: HistoryTableCoordinator) {
        let menu = NSMenu()
        for col in tableView.tableColumns {
            let item = NSMenuItem(
                title: col.title,
                action: #selector(HistoryTableCoordinator.toggleColumnVisibility(_:)),
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
final class HistoryDiffableDataSource: NSTableViewDiffableDataSource<Int, PlayHistoryRow.Key> {
    weak var coordinator: HistoryTableCoordinator?

    @objc func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange _: [NSSortDescriptor]
    ) {
        MainActor.assumeIsolated {
            self.coordinator?.handleSortChanged(in: tableView)
        }
    }
}
