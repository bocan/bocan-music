import AppKit
import Foundation
import SwiftUI

// MARK: - Coordinator

@MainActor
final class SubsonicSongTableCoordinator: NSObject, NSTableViewDelegate, NSMenuDelegate {
    var parent: SubsonicSongTable

    // Row data
    var rows: [SubsonicSongTableRow] = []
    var rowsByID: [String: SubsonicSongTableRow] = [:]

    // Snapshot-tracking
    var lastAppliedIDs: [String] = []
    var hasAppliedInitialSnapshot = false
    var lastRowDensity = UserDefaults.standard.string(forKey: "appearance.rowDensity") ?? "spacious"

    weak var tableView: NSTableView?
    var dataSource: SubsonicSongDiffableDataSource?

    private var paginationCooldown = false

    init(parent: SubsonicSongTable) {
        self.parent = parent
    }

    func updateRows(_ newRows: [SubsonicSongTableRow]) {
        self.rows = newRows
        self.rowsByID = Dictionary(newRows.map { ($0.id, $0) }) { _, new in new }
    }

    // MARK: Cell population

    func cellView(
        for column: NSTableColumn,
        songID: String,
        in tableView: NSTableView
    ) -> NSView? {
        guard let row = self.rowsByID[songID] else { return nil }
        let colID = column.identifier.rawValue

        if colID == "scol.art" {
            return self.artCell(for: row, in: tableView)
        }

        if colID == "scol.starred" {
            return self.starCell(for: row, in: tableView)
        }

        let cellID = NSUserInterfaceItemIdentifier("sTextCell.\(colID)")
        let cell: NSTableCellView = if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            reused
        } else {
            self.makeTextCell(cellID: cellID)
        }
        cell.textField?.stringValue = self.displayValue(colID: colID, row: row)
        cell.setAccessibilityLabel("\(column.title): \(cell.textField?.stringValue ?? "")")
        return cell
    }

    private func artCell(for row: SubsonicSongTableRow, in tableView: NSTableView) -> NSView {
        let cellID = NSUserInterfaceItemIdentifier("sArtCell")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? SubsonicCoverArtCell)
            ?? SubsonicCoverArtCell()
        cell.configure(
            provider: self.parent.coverArtProvider,
            serverID: self.parent.serverID,
            entityID: row.coverArtEntityID,
            seed: abs(row.id.hashValue),
            title: row.title
        )
        return cell
    }

    private func starCell(for row: SubsonicSongTableRow, in tableView: NSTableView) -> NSView {
        let cellID = NSUserInterfaceItemIdentifier("sStarCell")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? SubsonicStarButtonCell)
            ?? SubsonicStarButtonCell()
        cell.configure(starred: row.starred, action: self.parent.actions.toggleStar, songID: row.id)
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

    private func displayValue(colID: String, row: SubsonicSongTableRow) -> String {
        switch colID {
        case "scol.title":
            return row.title.isEmpty ? "Unknown" : row.title

        case "scol.artist":
            return row.artist

        case "scol.album":
            return row.album

        case "scol.year":
            return row.year > 0 ? String(row.year) : ""

        case "scol.genre":
            return row.genre

        case "scol.duration":
            let s = row.duration
            guard s > 0 else { return "" }
            return String(format: "%d:%02d", s / 60, s % 60)

        case "scol.trackNum":
            return row.trackNumber > 0 ? String(row.trackNumber) : ""

        case "scol.bitrate":
            return row.bitrate > 0 ? "\(row.bitrate) kbps" : ""

        case "scol.rating":
            let n = row.rating
            return n > 0 ? String(repeating: "★", count: min(n, 5)) : ""

        default:
            return ""
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
        guard row < self.rows.count else { return nil }
        let r = self.rows[row]
        let dur = r.duration > 0 ? String(format: "%d:%02d", r.duration / 60, r.duration % 60) : ""
        return "\(r.title), \(r.artist), \(r.album), \(dur)"
    }

    // MARK: Sort

    func handleSortChanged(in tableView: NSTableView) {
        guard let desc = tableView.sortDescriptors.first else { return }
        let asc = desc.ascending
        switch desc.key {
        case "title":
            self.rows.sort { asc ? $0.title < $1.title : $0.title > $1.title }

        case "artist":
            self.rows.sort { asc ? $0.artist < $1.artist : $0.artist > $1.artist }

        case "album":
            self.rows.sort { asc ? $0.album < $1.album : $0.album > $1.album }

        case "year":
            self.rows.sort { asc ? $0.year < $1.year : $0.year > $1.year }

        case "genre":
            self.rows.sort { asc ? $0.genre < $1.genre : $0.genre > $1.genre }

        case "duration":
            self.rows.sort { asc ? $0.duration < $1.duration : $0.duration > $1.duration }

        case "trackNum":
            self.rows.sort { asc ? $0.trackNumber < $1.trackNumber : $0.trackNumber > $1.trackNumber }

        case "bitrate":
            self.rows.sort { asc ? $0.bitrate < $1.bitrate : $0.bitrate > $1.bitrate }

        case "rating":
            self.rows.sort { asc ? $0.rating < $1.rating : $0.rating > $1.rating }

        case "starred":
            self.rows.sort { asc ? (!$0.starred && $1.starred) : ($0.starred && !$1.starred) }

        default:
            return
        }

        let newIDs = self.rows.map(\.id)
        self.lastAppliedIDs = newIDs
        var snap = NSDiffableDataSourceSnapshot<Int, String>()
        snap.appendSections([0])
        snap.appendItems(newIDs)
        self.dataSource?.apply(snap, animatingDifferences: false)
    }

    // MARK: Actions

    @objc func doubleClickAction(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0 else { return }
        self.parent.actions.playNow(row)
    }

    @objc func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let col = sender.representedObject as? NSTableColumn else { return }
        col.isHidden.toggle()
        sender.state = col.isHidden ? .off : .on
        let key = "bocan.col.hidden.bocan.subsonicSongsTable.v1.\(col.identifier.rawValue)"
        UserDefaults.standard.set(col.isHidden, forKey: key)
    }

    // MARK: NSMenuDelegate — context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tv = self.tableView else { return }

        // Select the clicked row if it's not already selected.
        let clickedRow = tv.clickedRow
        if clickedRow >= 0, !tv.selectedRowIndexes.contains(clickedRow) {
            tv.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        let selectedRows = Array(tv.selectedRowIndexes).sorted()
        guard !selectedRows.isEmpty else { return }

        let playItem = ActionMenuItem("Play") { [weak self] in
            guard let first = selectedRows.first else { return }
            self?.parent.actions.playNow(first)
        }
        menu.addItem(playItem)

        // Per-song annotation actions for single selection.
        if selectedRows.count == 1, let rowIdx = selectedRows.first, rowIdx < self.rows.count {
            let row = self.rows[rowIdx]
            menu.addItem(NSMenuItem.separator())

            let starTitle = row.starred ? "Unstar" : "Star"
            menu.addItem(ActionMenuItem(starTitle) { [weak self] in
                self?.parent.actions.toggleStar(row.id)
            })

            let ratingMenu = NSMenu(title: "Rating")
            for stars in 0 ... 5 {
                let label = stars == 0 ? "None" : String(repeating: "★", count: stars)
                let rItem = ActionMenuItem(label) { [weak self] in
                    self?.parent.actions.setRating(row.id, stars)
                }
                if stars == row.rating { rItem.state = .on }
                ratingMenu.addItem(rItem)
            }
            let ratingParent = NSMenuItem(title: "Rating", action: nil, keyEquivalent: "")
            ratingParent.submenu = ratingMenu
            menu.addItem(ratingParent)
        }
    }

    // MARK: Pagination

    @objc func scrollViewBoundsChanged(_ notification: Notification) {
        guard self.parent.hasMorePages,
              !self.parent.isLoading,
              !self.paginationCooldown else { return }
        guard let tv = self.tableView else { return }
        let visible = tv.rows(in: tv.visibleRect)
        guard NSMaxRange(visible) >= self.rows.count - 10 else { return }
        self.paginationCooldown = true
        self.parent.actions.loadMore()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.paginationCooldown = false
        }
    }
}
