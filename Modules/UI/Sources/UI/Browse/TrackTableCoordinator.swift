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

    /// What the last `updateNSView` applied: rows version, IDs, highlight,
    /// selection. `TrackTableUpdatePlan` diffs the next inputs against it (#450).
    var applied = TrackTableUpdatePlan.Applied()
    var hasAppliedInitialSnapshot = false
    /// Tracks the last scroll-request counter processed to avoid re-scrolling.
    var lastScrollRequest: Int = -1

    // Guards against feedback loops when syncing selection / sort.
    var isSyncingSelection = false
    var isSyncingSort = false

    /// Tracks the last-applied density so updateNSView can detect changes.
    var lastRowDensity = UserDefaults.standard.string(forKey: "appearance.rowDensity") ?? "spacious"

    // Owned AppKit objects — weak/strong to avoid retain cycles.
    weak var tableView: NSTableView?
    var dataSource: TrackDiffableDataSource?

    init(parent: TrackTable) {
        self.parent = parent
    }

    // MARK: Row data

    func updateRows(_ newRows: [TrackRow]) {
        self.rows = newRows
        // The same track can repeat in a playlist; keep one entry per ID
        // (last-writer-wins) for cell rendering.
        self.rowsByID = Dictionary(
            newRows.compactMap { row -> (Int64, TrackRow)? in
                guard let id = row.id else { return nil }
                return (id, row)
            }
        ) { _, new in new }
    }

    /// On-disk file URL for a local track row, to support dragging out to Finder (#311); nil for streamed sources.
    func fileURL(forTrackID id: Int64) -> URL? {
        guard let row = self.rowsByID[id],
              let url = URL(string: row.track.fileURL),
              url.isFileURL else { return nil }
        return url
    }

    // MARK: Cell population

    func cellView(
        for column: NSTableColumn,
        trackID: Int64,
        in tableView: NSTableView
    ) -> NSView? {
        guard let row = self.rowsByID[trackID] else { return nil }
        let isNowPlaying = self.parent.nowPlayingTrackID == row.id

        if column.identifier == .albumArt {
            return self.coverArtCell(for: row, in: tableView)
        }

        if column.identifier == .shuffleExclude {
            return self.shuffleCell(for: row, in: tableView)
        }

        if column.identifier == .loved {
            return self.loveCell(for: row, in: tableView)
        }

        let cellID = NSUserInterfaceItemIdentifier("textCell.\(column.identifier.rawValue)")
        let cell: NSTableCellView = if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            reused
        } else {
            self.makeTextCell(cellID: cellID)
        }
        cell.textField?.stringValue = TrackTable.displayValue(for: column.identifier, row: row)
        // preferredFont(forTextStyle:) scales with macOS text size settings.
        let baseFont = NSFont.preferredFont(forTextStyle: .body)
        cell.textField?.font = isNowPlaying
            ? NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
            : baseFont
        // Prefix the column name for VoiceOver; rating speaks as "3 stars".
        let colTitle = TrackTable.columnSpecs.first { $0.id == column.identifier }?.title ?? column.title
        let spokenValue: String
        if column.identifier == .rating {
            let stars = Formatters.stars(from: row.rating)
            spokenValue = stars == 0 ? L10n.string("Not rated") : L10n.string("\(stars) stars")
        } else {
            spokenValue = cell.textField?.stringValue ?? ""
        }
        cell.setAccessibilityLabel(L10n.string("\(colTitle): \(spokenValue)"))
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

    private func coverArtCell(for row: TrackRow, in tableView: NSTableView) -> NSView {
        let cellID = NSUserInterfaceItemIdentifier("artCell.albumArt")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? CoverArtImageCell)
            ?? CoverArtImageCell()
        cell.configure(artPath: row.coverArtPath, trackTitle: row.title)
        return cell
    }

    private func shuffleCell(for row: TrackRow, in tableView: NSTableView) -> NSView {
        let cellID = NSUserInterfaceItemIdentifier("checkCell.shuffleExclude")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? ShuffleCheckCell)
            ?? ShuffleCheckCell()
        cell.configure(row: row, action: self.parent.actions.toggleShuffle)
        return cell
    }

    private func loveCell(for row: TrackRow, in tableView: NSTableView) -> NSView {
        let cellID = NSUserInterfaceItemIdentifier("loveCell.loved")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? LoveButtonCell)
            ?? LoveButtonCell()
        cell.configure(row: row, action: self.parent.actions.love)
        return cell
    }

    // MARK: NSTableViewDelegate — accessibility

    /// One spoken sentence per row: "[Now playing, ]Title, Artist, Album, Duration".
    public func tableView(_ tableView: NSTableView, accessibilityLabelForRow row: Int) -> String? {
        guard row < self.rows.count else { return nil }
        let r = self.rows[row]
        let duration = Formatters.duration(r.duration)
        let isNowPlaying = self.parent.nowPlayingTrackID == r.id
        let prefix = isNowPlaying ? L10n.string("Now playing, ") : ""
        return "\(prefix)\(r.title), \(r.artistName), \(r.albumName), \(duration)"
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
              let key = TrackTable.sortKey(for: first) else {
            // Empty sort => manual order: clear any lingering column indicator.
            guard !tv.sortDescriptors.isEmpty else { return }
            self.isSyncingSort = true
            tv.sortDescriptors = []
            self.isSyncingSort = false
            return
        }
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
        // Option-double-click plays just this track; plain double-click replays
        // the surrounding browse-view context.
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
        // Persist visibility (autosaveTableColumns only saves width and order).
        if let autosaveName = tableView?.autosaveName {
            TrackTable.saveColumnVisibility(autosaveName: autosaveName, column: col)
        }
    }

    // MARK: Context menu: TrackTableCoordinator+ContextMenu.swift
}
