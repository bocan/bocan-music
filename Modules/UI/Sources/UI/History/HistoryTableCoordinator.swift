import AppKit
import Foundation
import Persistence

// MARK: - Coordinator

/// Delegate, cells, sort, paging and context menu for `HistoryTable` (ADR-094).
@MainActor
final class HistoryTableCoordinator: NSObject, NSTableViewDelegate, NSMenuDelegate {
    var parent: HistoryTable

    // Row data
    var rows: [PlayHistoryRow] = []
    var rowsByID: [PlayHistoryRow.Key: PlayHistoryRow] = [:]

    // Snapshot-tracking
    /// What the last `updateNSView` applied: rows version and the key list in
    /// the table's own order (#455).
    var applied = HistoryTableUpdatePlan.Applied()
    var hasAppliedInitialSnapshot = false
    /// The Played column's direction. The rows arrive newest first, which is
    /// descending; a header click flips it.
    var sortAscending = false

    weak var tableView: NSTableView?
    var dataSource: HistoryDiffableDataSource?

    private var paginationCooldown = false

    init(parent: HistoryTable) {
        self.parent = parent
    }

    func updateRows(_ newRows: [PlayHistoryRow]) {
        self.rows = newRows
        self.rowsByID = Dictionary(newRows.map { ($0.id, $0) }) { _, new in new }
    }

    /// The row keys in display order: the view model's newest-first order,
    /// reversed when the header sort is ascending.
    func orderedIDs() -> [PlayHistoryRow.Key] {
        let ids = self.rows.map(\.id)
        return self.sortAscending ? ids.reversed() : ids
    }

    // MARK: Cell population

    func cellView(
        for column: NSTableColumn,
        key: PlayHistoryRow.Key,
        in tableView: NSTableView
    ) -> NSView? {
        guard let row = self.rowsByID[key] else { return nil }
        let colID = column.identifier.rawValue
        let cellID = NSUserInterfaceItemIdentifier("hTextCell.\(colID)")
        let cell: NSTableCellView = if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            reused
        } else {
            self.makeTextCell(cellID: cellID)
        }
        let value = Self.displayValue(colID: colID, row: row)
        cell.textField?.stringValue = value
        // A listen of a song whose file has gone stays listed, greyed, the
        // way Up Next marks a song it cannot find. Reset on reuse.
        cell.textField?.textColor = row.isMissing ? .tertiaryLabelColor : .labelColor
        cell.toolTip = row.isMissing ? L10n.string("The file for this song is missing.") : nil
        cell.setAccessibilityLabel(L10n.string("\(column.title): \(value)"))
        return cell
    }

    private func makeTextCell(cellID: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = cellID
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    static func displayValue(colID: String, row: PlayHistoryRow) -> String {
        switch colID {
        case "hcol.playedAt":
            Formatters.shortDateTime(epochSeconds: row.playedAt)

        case "hcol.title":
            row.title ?? L10n.string("Unknown")

        case "hcol.artist":
            row.artistName ?? ""

        case "hcol.album":
            row.albumName ?? ""

        case "hcol.source":
            self.sourceName(row.source)

        default:
            ""
        }
    }

    /// The source as a person reads it: the player that recorded it, or the
    /// service the listen was imported from.
    static func sourceName(_ source: PlayHistoryRow.Source) -> String {
        switch source {
        case .local:
            L10n.string("Bòcan")

        case .imported:
            L10n.string("Last.fm")
        }
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch UserDefaults.standard.string(forKey: "appearance.rowDensity") {
        case "compact":
            22

        case "spacious":
            36

        default:
            28
        }
    }

    func tableView(_ tableView: NSTableView, accessibilityLabelForRow row: Int) -> String? {
        guard let key = self.dataSource?.itemIdentifier(forRow: row),
              let r = self.rowsByID[key] else { return nil }
        return [
            Formatters.shortDateTime(epochSeconds: r.playedAt),
            r.title ?? L10n.string("Unknown"),
            r.artistName ?? "",
            r.albumName ?? "",
            Self.sourceName(r.source),
            r.isMissing ? L10n.string("file missing") : "",
        ].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: Sort

    func handleSortChanged(in tableView: NSTableView) {
        guard let desc = tableView.sortDescriptors.first, desc.key == "playedAt" else { return }
        self.sortAscending = desc.ascending
        let ordered = self.orderedIDs()
        guard ordered != self.applied.ids else { return }
        self.applied.ids = ordered
        var snapshot = NSDiffableDataSourceSnapshot<Int, PlayHistoryRow.Key>()
        snapshot.appendSections([0])
        snapshot.appendItems(ordered)
        self.dataSource?.apply(snapshot, animatingDifferences: false)
    }

    // MARK: Paging

    /// Widens the window when the user is within ten rows of its end, once
    /// per second at most, and never while a load is already in flight.
    @objc func scrollViewBoundsChanged(_ notification: Notification) {
        guard self.parent.hasMore,
              !self.parent.isLoading,
              !self.paginationCooldown,
              let tv = self.tableView else { return }
        let visible = tv.rows(in: tv.visibleRect)
        guard NSMaxRange(visible) >= self.rows.count - 10 else { return }
        self.paginationCooldown = true
        self.parent.actions.loadMore()
        Task { @MainActor [weak self] in
            try await Task.sleep(for: .seconds(1))
            self?.paginationCooldown = false
        }
    }

    // MARK: Actions

    @objc func doubleClickAction(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, let key = self.dataSource?.itemIdentifier(forRow: row),
              self.rowsByID[key]?.isMissing == false else { return }
        self.parent.actions.playNow(key)
    }

    @objc func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let col = sender.representedObject as? NSTableColumn else { return }
        col.isHidden.toggle()
        sender.state = col.isHidden ? .off : .on
        let key = "bocan.col.hidden.bocan.historyTable.v1.\(col.identifier.rawValue)"
        UserDefaults.standard.set(col.isHidden, forKey: key)
    }

    // MARK: NSMenuDelegate, context menu

    /// The song actions, on the listens under the pointer. A right-click on
    /// a row outside the selection selects it first, as Finder and Music do.
    /// A row whose song row is gone gets no menu: there is nothing to act on.
    /// A row whose file is missing keeps the song actions (artist, album,
    /// Get Info) and loses the file ones (play, queue, Show in Finder).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tv = self.tableView, let dataSource = self.dataSource else { return }

        let clickedRow = tv.clickedRow
        if clickedRow >= 0, !tv.selectedRowIndexes.contains(clickedRow) {
            tv.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        let selected = tv.selectedRowIndexes
            .compactMap { dataSource.itemIdentifier(forRow: $0) }
            .compactMap { self.rowsByID[$0] }
            .filter { $0.title != nil }
        guard let first = selected.first else { return }
        let keys = selected.map(\.id)
        let playable = selected.filter { !$0.isMissing }
        let acts = self.parent.actions

        if let firstPlayable = playable.first {
            let playableKeys = playable.map(\.id)
            menu.addItem(ActionMenuItem(L10n.string("Play Now")) { acts.playNow(firstPlayable.id) })
            menu.addItem(ActionMenuItem(L10n.string("Play Next")) { acts.playNext(playableKeys) })
            menu.addItem(ActionMenuItem(L10n.string("Add to Queue")) { acts.addToQueue(playableKeys) })
        }

        if first.artistID != nil || first.albumID != nil {
            if menu.items.isEmpty == false {
                menu.addItem(.separator())
            }
            if let artistID = first.artistID {
                menu.addItem(ActionMenuItem(L10n.string("Go to Artist")) { acts.goToArtist(artistID) })
            }
            if let albumID = first.albumID {
                menu.addItem(ActionMenuItem(L10n.string("Go to Album")) { acts.goToAlbum(albumID) })
            }
        }

        if menu.items.isEmpty == false {
            menu.addItem(.separator())
        }
        if !first.isMissing {
            menu.addItem(ActionMenuItem(L10n.string("Show in Finder")) { acts.showInFinder(first.id) })
        }
        menu.addItem(ActionMenuItem(L10n.string("Get Info")) { acts.getInfo(keys) })
    }
}
