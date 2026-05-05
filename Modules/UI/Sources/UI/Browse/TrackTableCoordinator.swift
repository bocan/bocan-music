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

    /// Tracks the last-applied density so updateNSView can detect changes.
    var lastRowDensity = UserDefaults.standard.string(forKey: "appearance.rowDensity") ?? "regular"

    // Owned AppKit objects — weak/strong to avoid retain cycles.
    weak var tableView: NSTableView?
    var dataSource: TrackDiffableDataSource?

    init(parent: TrackTable) {
        self.parent = parent
    }

    // MARK: Row data

    func updateRows(_ newRows: [TrackRow]) {
        self.rows = newRows
        // Use uniquingKeysWith because the same track can appear more than once
        // in a playlist (different positions). We only need one lookup entry per
        // track ID for cell rendering; last-writer-wins is fine here.
        self.rowsByID = Dictionary(
            newRows.compactMap { row -> (Int64, TrackRow)? in
                guard let id = row.id else { return nil }
                return (id, row)
            }
        ) { _, new in new }
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
        // Give VoiceOver context by prefixing the column name.
        // Rating uses a spoken form ("3 stars") instead of the star glyphs.
        let colTitle = TrackTable.columnSpecs.first { $0.id == column.identifier }?.title ?? column.title
        let spokenValue: String
        if column.identifier == .rating {
            let stars = Formatters.stars(from: row.rating)
            spokenValue = stars == 0 ? "Not rated" : "\(stars) star\(stars == 1 ? "" : "s")"
        } else {
            spokenValue = cell.textField?.stringValue ?? ""
        }
        cell.setAccessibilityLabel("\(colTitle): \(spokenValue)")
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
        switch UserDefaults.standard.string(forKey: "appearance.rowDensity") {
        case "compact":
            22

        case "spacious":
            36

        default:
            28
        }
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
        // Option-double-click → play just this track, no context.  The default
        // double-click replays the surrounding browse-view context.
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            self.parent.actions.playSingle(trackRow.track)
        } else {
            self.parent.actions.playNow(trackRow.track)
        }
    }

    @objc func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let col = sender.representedObject as? NSTableColumn else { return }
        col.isHidden.toggle()
        sender.state = col.isHidden ? .off : .on
        // Persist visibility so it survives view recreation.
        // NSTableView.autosaveTableColumns only saves column width and order.
        if let autosaveName = tableView?.autosaveName {
            TrackTable.saveColumnVisibility(autosaveName: autosaveName, column: col)
        }
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
        self.addRateItem(to: menu, selected: selected, acts: acts)
        self.addNavigationItems(to: menu, selected: selected, first: first, acts: acts)
        self.addFileItems(to: menu, selected: selected, first: first, acts: acts)
        return menu
    }

    // MARK: Context menu — helpers

    /// Synchronises the table selection to the right-clicked row before building the context menu.
    ///
    /// This intentionally mirrors the standard macOS behaviour used by Finder and Music.app:
    ///
    /// - **Right-click inside the existing selection** — the `guard` exits immediately; the
    ///   multi-row selection is preserved and the menu applies to all selected rows.
    /// - **Right-click outside the existing selection** — the selection is replaced with the
    ///   single clicked row so the menu always targets a visible, unambiguous set of tracks.
    ///
    /// Do **not** remove the selection-replace branch; it is intentional, not a bug.
    private func syncClickedRow(in tv: NSTableView) {
        let clicked = tv.clickedRow
        // Already inside the selection — leave multi-row selection intact.
        guard clicked >= 0, !tv.selectedRowIndexes.contains(clicked) else { return }
        // Outside the selection — move selection to the clicked row (Finder / Music.app behaviour).
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

    /// Handles Return/Enter key presses from the table.
    /// Plays the first selected track using the same browse-view context as double-click.
    func handleReturnKeyDown() {
        guard let tableView = self.tableView,
              let firstIndex = tableView.selectedRowIndexes.first,
              let id = self.dataSource?.itemIdentifier(forRow: firstIndex),
              let trackRow = self.rowsByID[id] else { return }
        self.parent.actions.playNow(trackRow.track)
    }

    /// Handles Delete/Forward Delete key presses from the table.
    /// Returns `true` when consumed.
    func handleRemoveFromPlaylistKeyDown() -> Bool {
        guard let removeFromPlaylist = self.parent.actions.removeFromPlaylist else {
            return false
        }
        guard let tableView = self.tableView else {
            return false
        }
        let selected = tableView.selectedRowIndexes.compactMap { index -> Track? in
            guard let id = self.dataSource?.itemIdentifier(forRow: index) else {
                return nil
            }
            return self.rowsByID[id]?.track
        }
        guard !selected.isEmpty else {
            return false
        }
        removeFromPlaylist(selected)
        return true
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

    private func addRateItem(
        to menu: NSMenu,
        selected: [Track],
        acts: TrackContextMenuActions
    ) {
        guard !selected.isEmpty else { return }
        let rateMenu = NSMenu(title: "Rate")
        for star in 0 ... 5 {
            let label = star == 0
                ? "None"
                : String(repeating: "\u{2605}", count: star) + String(repeating: "\u{2606}", count: 5 - star)
            rateMenu.addItem(ActionMenuItem(label) { acts.rate(selected, star) })
        }
        let item = NSMenuItem(title: "Rate", action: nil, keyEquivalent: "")
        item.submenu = rateMenu
        menu.addItem(item)
    }

    private func addNavigationItems(
        to menu: NSMenu,
        selected: [Track],
        first: Track?,
        acts: TrackContextMenuActions
    ) {
        menu.addItem(.separator())
        var hasNav = false

        // All-same-album check: only show album actions when selection is within one album.
        let allSameAlbum = !selected.isEmpty
            && selected.allSatisfy { $0.albumID != nil && $0.albumID == selected[0].albumID }
        // All-same-artist check: only show artist action when selection is within one artist.
        let allSameArtist = !selected.isEmpty
            && selected.allSatisfy { $0.artistID != nil && $0.artistID == selected[0].artistID }

        if let track = first, allSameAlbum {
            menu.addItem(ActionMenuItem("Play Album") { acts.playAlbum(track) })
            menu.addItem(ActionMenuItem("Shuffle Album") { acts.shuffleAlbum(track) })
            hasNav = true
        }
        if let track = first, allSameArtist {
            menu.addItem(ActionMenuItem("Play Artist") { acts.playArtist(track) })
            hasNav = true
        }
        if hasNav { menu.addItem(.separator())
            hasNav = false
        }

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

        let rgItem = ActionMenuItem("Compute Replay Gain") { acts.computeReplayGain(selected) }
        rgItem.isEnabled = !selected.isEmpty
        menu.addItem(rgItem)

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
        let selectedRows = self.rows.filter { self.parent.selection.contains($0.id) }
        let copyItem = ActionMenuItem("Copy") { acts.copy(selectedRows) }
        copyItem.isEnabled = !selectedRows.isEmpty
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
