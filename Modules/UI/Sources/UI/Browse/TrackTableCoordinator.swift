import AppKit
import Library
import Persistence
import SwiftUI

// MARK: - TrackTableCoordinator

/// NSViewRepresentable coordinator for `TrackTable`.
@MainActor
public final class TrackTableCoordinator: NSObject, NSTableViewDelegate {
    var parent: TrackTable

    // Row data — kept in sync with the diffable snapshot.
    var rows: [TrackRow] = []
    var rowsByID: [Int64: TrackRow] = [:]

    // Change-detection state used in updateNSView.
    var lastAppliedIDs: [Int64] = []
    var lastNowPlayingID: Track.ID?
    var hasAppliedInitialSnapshot = false

    // Guards against feedback loops when syncing selection / sort.
    var isSyncingSelection = false
    var isSyncingSort = false

    // Owned AppKit objects — weak/strong to avoid retain cycles.
    weak var tableView: NSTableView?
    var dataSource: TrackDiffableDataSource?

    init(parent: TrackTable) {
        self.parent = parent
    }

    // MARK: Row data

    func updateRows(_ newRows: [TrackRow]) {
        self.rows = newRows
        self.rowsByID = Dictionary(
            uniqueKeysWithValues: newRows.compactMap { row in
                guard let id = row.id else { return nil }
                return (id, row)
            }
        )
    }

    // MARK: Cell population

    func cellView(
        for column: NSTableColumn,
        trackID: Int64,
        in tableView: NSTableView
    ) -> NSView? {
        guard let row = self.rowsByID[trackID] else { return nil }
        let isNowPlaying = self.parent.nowPlayingTrackID == row.id

        if column.identifier == .shuffleExclude {
            return self.shuffleCell(for: row, in: tableView)
        }

        let cellID = NSUserInterfaceItemIdentifier("textCell.\(column.identifier.rawValue)")
        let cell: NSTableCellView = if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            reused
        } else {
            self.makeTextCell(cellID: cellID)
        }
        cell.textField?.stringValue = TrackTable.displayValue(for: column.identifier, row: row)
        cell.textField?.font = isNowPlaying
            ? .boldSystemFont(ofSize: NSFont.systemFontSize)
            : .systemFont(ofSize: NSFont.systemFontSize)
        return cell
    }

    private func makeTextCell(cellID: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = cellID
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.truncatesLastVisibleLine = true
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func shuffleCell(for row: TrackRow, in tableView: NSTableView) -> NSView {
        let cellID = NSUserInterfaceItemIdentifier("checkCell.shuffleExclude")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? ShuffleCheckCell)
            ?? ShuffleCheckCell()
        cell.configure(row: row, action: self.parent.actions.toggleShuffle)
        return cell
    }

    // MARK: NSTableViewDelegate — sort / selection / layout

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        22
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !self.isSyncingSelection else { return }
        guard let tv = notification.object as? NSTableView else { return }
        let newIDs = Set(
            tv.selectedRowIndexes.compactMap { idx -> Track.ID? in
                self.dataSource?.itemIdentifier(forRow: idx)
            }
        )
        // Defer to avoid publishing inside AppKit's table layout (SwiftUI runtime fault).
        Task { @MainActor [weak self] in self?.parent.selection = newIDs }
    }

    func handleSortDescriptorsDidChange(in tableView: NSTableView) {
        guard self.parent.sortable, !self.isSyncingSort else { return }
        let newOrder = tableView.sortDescriptors.compactMap {
            TrackTable.comparator(from: $0)
        }
        guard !newOrder.isEmpty else { return }
        self.parent.sortOrder = newOrder
    }

    func syncSortIfNeeded(sortOrder: [KeyPathComparator<TrackRow>]) {
        guard let tv = tableView else { return }
        guard let first = sortOrder.first,
              let key = TrackTable.sortKey(for: first) else { return }
        let desired = [NSSortDescriptor(key: key, ascending: first.order == .forward)]
        guard tv.sortDescriptors != desired else { return }
        self.isSyncingSort = true
        tv.sortDescriptors = desired
        self.isSyncingSort = false
    }

    // MARK: Actions

    @objc func doubleClickAction(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, let id = dataSource?.itemIdentifier(forRow: row),
              let trackRow = rowsByID[id] else { return }
        self.parent.actions.playNow(trackRow.track)
    }

    @objc func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let col = sender.representedObject as? NSTableColumn else { return }
        col.isHidden.toggle()
        sender.state = col.isHidden ? .off : .on
    }

    // MARK: Context menu — main entry

    func buildContextMenu() -> NSMenu {
        guard let tv = tableView else { return NSMenu() }
        self.syncClickedRow(in: tv)
        let selected = self.selectedTracks()
        let first = selected.first
        let acts = self.parent.actions
        let menu = NSMenu()
        self.addPlaybackItems(to: menu, selected: selected, first: first, acts: acts)
        self.addLoveItem(to: menu, first: first, acts: acts)
        self.addNavigationItems(to: menu, first: first, acts: acts)
        self.addFileItems(to: menu, selected: selected, first: first, acts: acts)
        return menu
    }

    // MARK: Context menu — helpers

    private func syncClickedRow(in tv: NSTableView) {
        let clicked = tv.clickedRow
        guard clicked >= 0, !tv.selectedRowIndexes.contains(clicked) else { return }
        self.isSyncingSelection = true
        tv.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        self.isSyncingSelection = false
        if let id = dataSource?.itemIdentifier(forRow: clicked) {
            self.parent.selection = [id]
        }
    }

    private func selectedTracks() -> [Track] {
        let sel = self.parent.selection
        return self.rows.filter { sel.contains($0.id) }.map(\.track)
    }

    private func addPlaybackItems(
        to menu: NSMenu,
        selected: [Track],
        first: Track?,
        acts: TrackContextMenuActions
    ) {
        if let track = first {
            menu.addItem(ActionMenuItem("Play Now") { acts.playNow(track) })
        }
        let playNextItem = ActionMenuItem("Play Next") { acts.playNext(selected) }
        playNextItem.isEnabled = !selected.isEmpty
        menu.addItem(playNextItem)
        let addQueueItem = ActionMenuItem("Add to Queue") { acts.addToQueue(selected) }
        addQueueItem.isEnabled = !selected.isEmpty
        menu.addItem(addQueueItem)

        let sub = NSMenu()
        sub.addItem(ActionMenuItem("New Playlist from Selection…") {
            acts.newPlaylistFromSelection(selected)
        })
        if !self.parent.playlistNodes.isEmpty { sub.addItem(.separator()) }
        Self.fillPlaylistSubmenu(
            sub, nodes: self.parent.playlistNodes, tracks: selected, action: acts.addToPlaylist
        )
        let playlistItem = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
        playlistItem.submenu = sub
        menu.addItem(playlistItem)
    }

    private func addLoveItem(
        to menu: NSMenu,
        first: Track?,
        acts: TrackContextMenuActions
    ) {
        guard let track = first else { return }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(track.loved ? "Unlove" : "Love") { acts.love(track) })
    }

    private func addNavigationItems(
        to menu: NSMenu,
        first: Track?,
        acts: TrackContextMenuActions
    ) {
        menu.addItem(.separator())
        var hasNav = false
        if let id = first?.artistID {
            menu.addItem(ActionMenuItem("Go to Artist") { acts.goToArtist(id) })
            hasNav = true
        }
        if let id = first?.albumID {
            menu.addItem(ActionMenuItem("Go to Album") { acts.goToAlbum(id) })
            hasNav = true
        }
        if hasNav { menu.addItem(.separator()) }
    }

    private func addFileItems(
        to menu: NSMenu,
        selected: [Track],
        first: Track?,
        acts: TrackContextMenuActions
    ) {
        if let track = first {
            menu.addItem(ActionMenuItem("Show in Finder") { acts.showInFinder(track) })
            menu.addItem(ActionMenuItem("Re-scan File") { acts.rescanFile(track) })
        }
        let infoItem = ActionMenuItem("Get Info") { acts.getInfo(selected) }
        infoItem.isEnabled = !selected.isEmpty
        menu.addItem(infoItem)

        if let track = first {
            let identifyItem = ActionMenuItem("Identify Track\u{2026}") { acts.identify(track) }
            identifyItem.isEnabled = selected.count == 1
            menu.addItem(identifyItem)
        }

        menu.addItem(.separator())
        if let removeFromPlaylist = acts.removeFromPlaylist {
            let rp = ActionMenuItem("Remove from Playlist") { removeFromPlaylist(selected) }
            rp.isEnabled = !selected.isEmpty
            menu.addItem(rp)
        }
        let removeItem = ActionMenuItem("Remove from Library") { acts.removeFromLibrary(selected) }
        removeItem.isEnabled = !selected.isEmpty
        menu.addItem(removeItem)
        if let track = first {
            menu.addItem(ActionMenuItem("Delete from Disk") { acts.deleteFromDisk(track) })
        }
        menu.addItem(.separator())
        let copyItem = ActionMenuItem("Copy") { acts.copy(selected) }
        copyItem.isEnabled = !selected.isEmpty
        menu.addItem(copyItem)
    }

    private static func fillPlaylistSubmenu(
        _ menu: NSMenu,
        nodes: [PlaylistNode],
        tracks: [Track],
        action: @escaping (Int64, [Track]) -> Void
    ) {
        for node in nodes {
            if node.kind == .folder {
                let sub = NSMenu()
                self.fillPlaylistSubmenu(sub, nodes: node.children, tracks: tracks, action: action)
                let item = NSMenuItem(title: node.name, action: nil, keyEquivalent: "")
                item.submenu = sub
                menu.addItem(item)
            } else if node.kind == .manual {
                let id = node.id
                menu.addItem(ActionMenuItem(node.name) { action(id, tracks) })
            }
            // Smart playlists are read-only — skip them entirely.
        }
    }
}

// MARK: - ActionMenuItem

/// `NSMenuItem` that executes a closure when activated.  Owns the block
/// as its target to avoid external retain cycles.
final class ActionMenuItem: NSMenuItem {
    private let block: () -> Void

    init(_ title: String, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(Self.fire), keyEquivalent: "")
        self.target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("unavailable")
    }

    @objc private func fire() {
        self.block()
    }
}

// MARK: - ShuffleCheckCell

/// `NSTableCellView` subclass for the Shuffle Exclude column.
final class ShuffleCheckCell: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var trackID: Int64?
    private var onToggle: ((Int64, Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("checkCell.shuffleExclude")
        self.checkbox.translatesAutoresizingMaskIntoConstraints = false
        self.checkbox.target = self
        self.checkbox.action = #selector(self.checkboxChanged(_:))
        addSubview(self.checkbox)
        NSLayoutConstraint.activate([
            self.checkbox.centerXAnchor.constraint(equalTo: centerXAnchor),
            self.checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("unavailable")
    }

    func configure(row: TrackRow, action: @escaping (Int64, Bool) -> Void) {
        self.trackID = row.id
        self.onToggle = action
        self.checkbox.state = row.excludedFromShuffle ? .on : .off
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        guard let id = trackID else { return }
        self.onToggle?(id, sender.state == .on)
    }
}

// MARK: - TrackDiffableDataSource

/// Subclass of `NSTableViewDiffableDataSource` that adds drag-to-playlist
/// support by implementing `tableView(_:pasteboardWriterForRow:)`.
/// The section identifier is a single `Int` (0); item identifiers are `Int64` track IDs.
@MainActor
final class TrackDiffableDataSource: NSTableViewDiffableDataSource<Int, Int64> {
    /// Forwarded to the coordinator so sort-descriptor changes reach SwiftUI.
    weak var coordinator: TrackTableCoordinator?

    @objc func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange _: [NSSortDescriptor]
    ) {
        MainActor.assumeIsolated {
            self.coordinator?.handleSortDescriptorsDidChange(in: tableView)
        }
    }

    @objc func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard let id = itemIdentifier(forRow: row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(id), forType: .string)
        return item
    }
}
