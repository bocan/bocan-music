import AppKit
import Persistence
import SwiftUI

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

    /// When non-nil, the data source participates in intra-table reorder.
    var onMove: ((IndexSet, Int) -> Void)?

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

    // MARK: - Drag-reorder (intra-table)

    /// Validate a drop: only allow intra-table reorder when `onMove` is set.
    @objc func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard self.onMove != nil,
              info.draggingSource as? NSTableView === tableView else { return [] }
        // Only allow drop between rows, not onto a row.
        if dropOperation == .on {
            tableView.setDropRow(row, dropOperation: .above)
        }
        return .move
    }

    /// Accept the drop and call `onMove` with SwiftUI-style indices.
    @objc func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let onMove = self.onMove,
              info.draggingSource as? NSTableView === tableView else { return false }

        // Collect the dragged row indices by looking up each pasteboard item's
        // track-ID string and finding its current index in the snapshot.
        var sourceIndices = IndexSet()
        info.draggingPasteboard.pasteboardItems?.forEach { item in
            guard let str = item.string(forType: .string),
                  let trackID = Int64(str) else { return }
            if let idx = self.row(forItemIdentifier: trackID), idx >= 0 {
                sourceIndices.insert(idx)
            }
        }
        guard !sourceIndices.isEmpty else { return false }

        onMove(sourceIndices, row)
        return true
    }
}
