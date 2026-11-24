import AppKit
import Foundation
import Jellyfin
import SwiftUI

// MARK: - Cover cell

/// `NSTableCellView` that loads the cover art for a Jellyfin song. It resolves
/// the URL through `JellyfinCoverArtProvider`, then loads the image through the
/// shared image cache. It cancels in-flight work when reused.
final class JellyfinCoverArtCell: NSTableCellView {
    private let imageContainer = NSView()
    private let artImageView = NSImageView()
    private var loadTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("jArtCell")

        self.imageContainer.translatesAutoresizingMaskIntoConstraints = false
        self.imageContainer.wantsLayer = true
        self.imageContainer.layer?.cornerRadius = 3
        self.imageContainer.layer?.masksToBounds = true
        addSubview(self.imageContainer)

        self.artImageView.translatesAutoresizingMaskIntoConstraints = false
        self.artImageView.imageScaling = .scaleProportionallyUpOrDown
        self.artImageView.imageAlignment = .alignCenter
        self.artImageView.animates = false
        self.imageContainer.addSubview(self.artImageView)

        NSLayoutConstraint.activate([
            self.imageContainer.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            self.imageContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            self.imageContainer.widthAnchor.constraint(equalTo: self.imageContainer.heightAnchor),
            self.imageContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            self.artImageView.leadingAnchor.constraint(equalTo: self.imageContainer.leadingAnchor),
            self.artImageView.trailingAnchor.constraint(equalTo: self.imageContainer.trailingAnchor),
            self.artImageView.topAnchor.constraint(equalTo: self.imageContainer.topAnchor),
            self.artImageView.bottomAnchor.constraint(equalTo: self.imageContainer.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("unavailable")
    }

    func configure(
        provider: JellyfinCoverArtProvider?,
        serverID: UUID,
        itemID: String?,
        tag: String?,
        title: String
    ) {
        self.loadTask?.cancel()
        self.artImageView.image = nil
        setAccessibilityLabel(itemID == nil ? L10n.string("No artwork") : L10n.string("\(title) artwork"))
        guard let provider, let itemID else { return }
        self.loadTask = Task { @MainActor [weak self] in
            let url: URL?
            do {
                url = try await provider.coverArtURL(serverID: serverID, itemID: itemID, tag: tag, size: 64)
            } catch {
                // The provider has already logged the failure (without the URL).
                return
            }
            guard let url, !Task.isCancelled else { return }
            // The image cache is shared with the Subsonic table: it holds decoded
            // images by URL and knows nothing about either server kind.
            let img = await SubsonicImageCache.shared.image(url: url)
            guard !Task.isCancelled else { return }
            self?.artImageView.image = img
        }
    }
}

// MARK: - Coordinator

@MainActor
final class JellyfinSongTableCoordinator: NSObject, NSTableViewDelegate, NSMenuDelegate {
    var parent: JellyfinSongTable

    // Row data
    var rows: [JellyfinSongTableRow] = []
    var rowsByID: [String: JellyfinSongTableRow] = [:]

    /// What the last `updateNSView` applied: rows version and the ID list in the
    /// table's own order, which a header-click sort rewrites (#455).
    var applied = JellyfinSongTableUpdatePlan.Applied()
    var hasAppliedInitialSnapshot = false
    /// Row ID last driven onto the selection by the now-playing sync, so the
    /// selection follows the playing song only when it changes.
    var lastNowPlayingRowID: String?

    weak var tableView: NSTableView?
    var dataSource: JellyfinSongDiffableDataSource?

    private var paginationCooldown = false

    init(parent: JellyfinSongTable) {
        self.parent = parent
    }

    func updateRows(_ newRows: [JellyfinSongTableRow]) {
        self.rows = newRows
        self.rowsByID = Dictionary(newRows.map { ($0.id, $0) }) { _, new in new }
    }

    /// Moves the selection onto the now-playing row, only when the now-playing
    /// identity changes. A no-op when the row is not loaded yet.
    func syncSelectionToNowPlaying(_ rowID: String?) {
        guard rowID != self.lastNowPlayingRowID else { return }
        self.lastNowPlayingRowID = rowID
        guard let rowID,
              let tableView = self.tableView,
              let index = self.applied.ids.firstIndex(of: rowID) else { return }
        guard tableView.selectedRowIndexes != IndexSet(integer: index) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    /// Drag payload for a row, used to drag a streamed song into the queue.
    func dragPayload(forID id: String) -> JellyfinSongDragPayload? {
        guard let row = self.rowsByID[id] else { return nil }
        return JellyfinSongDragPayload(song: row.song, serverID: row.serverID)
    }

    // MARK: Cell population

    func cellView(for column: NSTableColumn, songID: String, in tableView: NSTableView) -> NSView? {
        guard let row = self.rowsByID[songID] else { return nil }
        let colID = column.identifier.rawValue

        if colID == "jcol.art" {
            return self.artCell(for: row, in: tableView)
        }
        if colID == "jcol.starred" {
            return self.starCell(for: row, in: tableView)
        }

        let cellID = NSUserInterfaceItemIdentifier("jTextCell.\(colID)")
        let cell: NSTableCellView = if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            reused
        } else {
            self.makeTextCell(cellID: cellID)
        }
        cell.textField?.stringValue = self.displayValue(colID: colID, row: row)
        cell.textField?.textColor = colID == "jcol.starred" && row.starred ? .systemYellow : .labelColor
        cell.setAccessibilityLabel(self.accessibilityText(colID: colID, column: column, row: row, cell: cell))
        return cell
    }

    private func accessibilityText(colID: String, column: NSTableColumn, row: JellyfinSongTableRow, cell: NSTableCellView) -> String {
        if colID == "jcol.starred" {
            return row.starred ? L10n.string("Starred") : L10n.string("Not starred")
        }
        return L10n.string("\(column.title): \(cell.textField?.stringValue ?? "")")
    }

    private func artCell(for row: JellyfinSongTableRow, in tableView: NSTableView) -> NSView {
        let cellID = NSUserInterfaceItemIdentifier("jArtCell")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? JellyfinCoverArtCell)
            ?? JellyfinCoverArtCell()
        cell.configure(
            provider: self.parent.coverArtProvider,
            serverID: row.serverID,
            itemID: row.song.coverArtID,
            tag: row.song.coverArtTag,
            title: row.title
        )
        return cell
    }

    /// The star button. The cell is the Subsonic one, reused unchanged: it
    /// carries nothing Subsonic specific (ADR-097, D1). Its id is the row id.
    private func starCell(for row: JellyfinSongTableRow, in tableView: NSTableView) -> NSView {
        let cellID = NSUserInterfaceItemIdentifier("sStarCell")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? SubsonicStarButtonCell)
            ?? SubsonicStarButtonCell()
        cell.configure(starred: row.starred, action: { [weak self] rowID in self?.toggleStar(rowID: rowID) }, songID: row.id)
        return cell
    }

    private func toggleStar(rowID: String) {
        guard let row = self.rowsByID[rowID] else { return }
        self.parent.actions.toggleStar(row)
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

    private func displayValue(colID: String, row: JellyfinSongTableRow) -> String {
        switch colID {
        case "jcol.title":
            row.title.isEmpty ? L10n.string("Unknown") : row.title

        case "jcol.artist":
            row.artist

        case "jcol.album":
            row.album

        case "jcol.year":
            row.year > 0 ? String(row.year) : ""

        case "jcol.genre":
            row.genre

        case "jcol.duration":
            Self.formatDuration(row.duration)

        case "jcol.trackNum":
            row.trackNumber > 0 ? String(row.trackNumber) : ""

        case "jcol.bitrate":
            row.bitrate > 0 ? L10n.string("\(row.bitrate) kbps") : ""

        case "jcol.starred":
            "\u{2605}"

        case "jcol.source":
            row.serverName

        default:
            ""
        }
    }

    static func formatDuration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
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

        case "starred":
            self.rows.sort { asc ? (!$0.starred && $1.starred) : ($0.starred && !$1.starred) }

        case "source":
            self.rows.sort { asc ? $0.serverName < $1.serverName : $0.serverName > $1.serverName }

        default:
            return
        }

        let newIDs = self.rows.map(\.id)
        self.applied.ids = newIDs
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
        let key = "bocan.col.hidden.\(JellyfinSongTable.autosaveName).\(col.identifier.rawValue)"
        UserDefaults.standard.set(col.isHidden, forKey: key)
    }

    // MARK: NSMenuDelegate: context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tv = self.tableView else { return }

        // Select the clicked row if it is not already selected.
        let clickedRow = tv.clickedRow
        if clickedRow >= 0, !tv.selectedRowIndexes.contains(clickedRow) {
            tv.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        guard let first = tv.selectedRowIndexes.min() else { return }
        menu.addItem(ActionMenuItem(L10n.string("Play")) { [weak self] in
            self?.parent.actions.playNow(first)
        })

        // Favourite for a single selection, as the Subsonic table offers.
        if tv.selectedRowIndexes.count == 1, first < self.rows.count {
            let row = self.rows[first]
            menu.addItem(NSMenuItem.separator())
            menu.addItem(ActionMenuItem(row.starred ? L10n.string("Unstar") : L10n.string("Star")) { [weak self] in
                self?.parent.actions.toggleStar(row)
            })
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
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                // Cancelled: the cooldown still has to end.
            }
            self?.paginationCooldown = false
        }
    }
}
