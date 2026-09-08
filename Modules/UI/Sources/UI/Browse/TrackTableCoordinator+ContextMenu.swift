import AppKit
import Library
import Persistence
import SwiftUI

// MARK: - TrackTableCoordinator context menu

/// The right-click menu and the two key handlers that share its selection
/// logic. Split from `TrackTableCoordinator.swift` to keep that file and the
/// class body inside the lint limits; extensions do not count toward the
/// type body length. `addShuffleItem` lives in `TrackTableHelpers.swift`.
extension TrackTableCoordinator {
    // MARK: Context menu, main entry

    func buildContextMenu() -> NSMenu {
        guard let tv = tableView else { return NSMenu() }
        self.syncClickedRow(in: tv)
        let selected = self.selectedTracks(in: tv)
        let first = selected.first
        let acts = self.parent.actions
        let menu = NSMenu()
        self.addPlaybackItems(to: menu, selected: selected, first: first, acts: acts)
        self.addLoveItem(to: menu, selected: selected, acts: acts)
        self.addRateItem(to: menu, selected: selected, acts: acts)
        self.addShuffleItem(to: menu, selected: selected, acts: acts)
        self.addNavigationItems(to: menu, selected: selected, first: first, acts: acts)
        self.addLyricsItems(to: menu, selected: selected, first: first, acts: acts)
        self.addFileItems(to: menu, selected: selected, first: first, acts: acts)
        return menu
    }

    // MARK: Context menu, helpers

    /// Syncs selection to the right-clicked row before building the menu,
    /// mirroring Finder / Music.app. Do not remove the selection-replace branch
    /// (a click outside the selection replaces it); it is intentional, not a bug.
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

    /// The menu's tracks, from the table's own selection: `syncClickedRow` has
    /// just written the binding, and a binding write is not readable in the
    /// same pass, so `parent.selection` still showed the pre-click selection.
    private func selectedTracks(in tv: NSTableView) -> [Track] {
        tv.selectedRowIndexes.compactMap { idx in
            self.dataSource?.itemIdentifier(forRow: idx).flatMap { self.rowsByID[$0]?.track }
        }
    }

    /// Return/Enter plays the first selected track, like double-click.
    func handleReturnKeyDown() {
        guard let tableView = self.tableView,
              let firstIndex = tableView.selectedRowIndexes.first,
              let id = self.dataSource?.itemIdentifier(forRow: firstIndex),
              let trackRow = self.rowsByID[id] else { return }
        self.parent.actions.playNow(trackRow.track)
    }

    /// Delete/Forward Delete removes from the playlist; returns `true` when consumed.
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
            menu.addItem(ActionMenuItem(L10n.string("Play Now")) { acts.playNow(track) })
        }
        let playNextItem = ActionMenuItem(L10n.string("Play Next")) { acts.playNext(selected) }
        playNextItem.isEnabled = !selected.isEmpty
        menu.addItem(playNextItem)
        let addQueueItem = ActionMenuItem(L10n.string("Add to Queue")) { acts.addToQueue(selected) }
        addQueueItem.isEnabled = !selected.isEmpty
        menu.addItem(addQueueItem)

        let sub = NSMenu()
        sub.addItem(ActionMenuItem(L10n.string("New Playlist from Selection…")) {
            acts.newPlaylistFromSelection(selected)
        })
        if !self.parent.playlistNodes.isEmpty {
            sub.addItem(.separator())
        }
        Self.fillPlaylistSubmenu(
            sub, nodes: self.parent.playlistNodes, tracks: selected, action: acts.addToPlaylist
        )
        let playlistItem = NSMenuItem(title: L10n.string("Add to Playlist"), action: nil, keyEquivalent: "")
        playlistItem.submenu = sub
        menu.addItem(playlistItem)

        // Grouped here, not with the removals; ⌫ is display-only (table handles it).
        if let removeFromPlaylist = acts.removeFromPlaylist {
            let rp = ActionMenuItem(L10n.string("Remove from Playlist")) { removeFromPlaylist(selected) }
            rp.isEnabled = !selected.isEmpty
            rp.keyEquivalent = "\u{8}"
            rp.keyEquivalentModifierMask = []
            menu.addItem(rp)
        }
    }

    private func addLoveItem(
        to menu: NSMenu,
        selected: [Track],
        acts: TrackContextMenuActions
    ) {
        guard !selected.isEmpty else { return }
        let allLoved = selected.allSatisfy(\.loved)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(allLoved ? L10n.string("Unlove") : L10n.string("Love")) { acts.love(selected) })
    }

    private func addRateItem(
        to menu: NSMenu,
        selected: [Track],
        acts: TrackContextMenuActions
    ) {
        guard !selected.isEmpty else { return }
        let rateMenu = NSMenu(title: L10n.string("Rate"))
        for star in 0 ... 5 {
            let label = star == 0
                ? L10n.string("None")
                : String(repeating: "\u{2605}", count: star) + String(repeating: "\u{2606}", count: 5 - star)
            rateMenu.addItem(ActionMenuItem(label) { acts.rate(selected, star) })
        }
        let item = NSMenuItem(title: L10n.string("Rate"), action: nil, keyEquivalent: "")
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
            menu.addItem(ActionMenuItem(L10n.string("Play Album")) { acts.playAlbum(track) })
            menu.addItem(ActionMenuItem(L10n.string("Shuffle Album")) { acts.shuffleAlbum(track) })
            hasNav = true
        }
        if let track = first, allSameArtist {
            menu.addItem(ActionMenuItem(L10n.string("Play Artist")) { acts.playArtist(track) })
            hasNav = true
        }
        if hasNav {
            menu.addItem(.separator())
            hasNav = false
        }

        if let id = first?.artistID {
            menu.addItem(ActionMenuItem(L10n.string("Go to Artist")) { acts.goToArtist(id) })
            hasNav = true
        }
        if let id = first?.albumID {
            menu.addItem(ActionMenuItem(L10n.string("Go to Album")) { acts.goToAlbum(id) })
            hasNav = true
        }
        if hasNav {
            menu.addItem(.separator())
        }
    }

    private func addLyricsItems(
        to menu: NSMenu,
        selected: [Track],
        first: Track?,
        acts: TrackContextMenuActions
    ) {
        guard first != nil else { return }
        guard acts.editLyrics != nil || acts.fetchLyricsFromLRClib != nil else { return }
        menu.addItem(.separator())
        if let editLyrics = acts.editLyrics, let track = first {
            let item = ActionMenuItem(L10n.string("Edit Lyrics\u{2026}")) { editLyrics(track) }
            item.isEnabled = selected.count == 1
            menu.addItem(item)
        }
        if let fetchLyrics = acts.fetchLyricsFromLRClib, let track = first {
            let item = ActionMenuItem(L10n.string("Fetch Lyrics from LRClib")) { fetchLyrics(track) }
            item.isEnabled = selected.count == 1
            menu.addItem(item)
        }
    }

    private func addFileItems(
        to menu: NSMenu,
        selected: [Track],
        first: Track?,
        acts: TrackContextMenuActions
    ) {
        if let track = first {
            menu.addItem(ActionMenuItem(L10n.string("Show in Finder")) { acts.showInFinder(track) })
            menu.addItem(ActionMenuItem(L10n.string("Re-scan File")) { acts.rescanFile(track) })
        }
        let infoItem = ActionMenuItem(L10n.string("Get Info")) { acts.getInfo(selected) }
        infoItem.isEnabled = !selected.isEmpty
        menu.addItem(infoItem)

        if let track = first {
            let identifyItem = ActionMenuItem(L10n.string("Identify Track\u{2026}")) { acts.identify(track) }
            identifyItem.isEnabled = selected.count == 1
            menu.addItem(identifyItem)
        }

        let rgItem = ActionMenuItem(L10n.string("Compute Replay Gain")) { acts.computeReplayGain(selected) }
        rgItem.isEnabled = !selected.isEmpty
        menu.addItem(rgItem)

        menu.addItem(.separator())
        let removeItem = ActionMenuItem(L10n.string("Remove from Library")) { acts.removeFromLibrary(selected) }
        removeItem.isEnabled = !selected.isEmpty
        menu.addItem(removeItem)
        let deleteItem = ActionMenuItem(L10n.string("Delete from Disk")) { acts.deleteFromDisk(selected) }
        deleteItem.isEnabled = !selected.isEmpty
        menu.addItem(deleteItem)
        menu.addItem(.separator())
        let selectedRows = self.parent.selection.compactMap { id in id.flatMap { self.rowsByID[$0] } }
        let copyItem = ActionMenuItem(L10n.string("Copy")) { acts.copy(selectedRows) }
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
            // Smart playlists are read-only, so they are skipped entirely.
        }
    }
}
