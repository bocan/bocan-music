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

// MARK: - Shuffle-exclusion menu item

extension TrackTableCoordinator {
    /// "Exclude from Shuffle" / "Include in Shuffle" toggle, love-item style:
    /// an all-excluded selection offers include; anything else excludes all.
    /// Lives here (not in the coordinator file) for `file_length` headroom.
    func addShuffleItem(to menu: NSMenu, selected: [Track], acts: TrackContextMenuActions) {
        guard !selected.isEmpty else { return }
        let allExcluded = selected.allSatisfy(\.excludedFromShuffle)
        let title = allExcluded ? L10n.string("Include in Shuffle") : L10n.string("Exclude from Shuffle")
        menu.addItem(ActionMenuItem(title) {
            for id in selected.compactMap(\.id) {
                acts.toggleShuffle(id, !allExcluded)
            }
        })
    }
}

// MARK: - ShuffleCheckCell

/// `NSTableCellView` subclass for the Shuffle Exclude column.
final class ShuffleCheckCell: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var trackID: Int64?
    private var trackTitle = ""
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
        self.trackTitle = row.title
        self.onToggle = action
        self.checkbox.state = row.excludedFromShuffle ? .on : .off
        self.updateAccessibilityLabel()
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        guard let id = trackID else { return }
        self.onToggle?(id, sender.state == .on)
        self.updateAccessibilityLabel()
    }

    private func updateAccessibilityLabel() {
        self.checkbox.setAccessibilityLabel(L10n.string("Exclude \(self.trackTitle) from shuffle"))
    }
}

// MARK: - LoveButtonCell

/// `NSTableCellView` subclass for the Loved (♥) column.
/// Shows a filled red heart when loved and a faint outline heart when not.
/// Clicking the cell toggles the loved state on just that one track.
final class LoveButtonCell: NSTableCellView {
    private static let lovedColor = NSColor(Color.lovedTint)

    private let button = NSButton(frame: .zero)
    private var track: Track?
    private var onToggle: (([Track]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("loveCell.loved")
        self.button.translatesAutoresizingMaskIntoConstraints = false
        self.button.isBordered = false
        self.button.bezelStyle = .inline
        self.button.target = self
        self.button.action = #selector(self.tapped)
        addSubview(self.button)
        NSLayoutConstraint.activate([
            self.button.centerXAnchor.constraint(equalTo: centerXAnchor),
            self.button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("unavailable")
    }

    func configure(row: TrackRow, action: @escaping ([Track]) -> Void) {
        self.track = row.track
        self.onToggle = action
        // Use preferredFont so the heart scales with macOS text size settings.
        let bodyFont = NSFont.preferredFont(forTextStyle: .body)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: row.loved ? Self.lovedColor : NSColor.tertiaryLabelColor,
        ]
        self.button.attributedTitle = NSAttributedString(string: row.loved ? "\u{2665}" : "\u{2661}", attributes: attrs)
        self.button.setAccessibilityLabel(row.loved ? L10n.string("Loved") : L10n.string("Not loved"))
        self.button.toolTip = row.loved ? L10n.string("Loved — click to unlove") : L10n.string("Click to love")
    }

    @objc private func tapped() {
        guard let track else { return }
        self.onToggle?([track])
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
    /// When non-nil, songs dragged from another table in the app drop here,
    /// above the row under the pointer (#709).
    var onDropTracks: (([Int64], Int) -> Void)?

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
        // The track-ID string drives intra-table reorder; the file URL lets the
        // same drag drop a real file onto Finder/Desktop or another app (#311).
        item.setString(String(id), forType: .string)
        MainActor.assumeIsolated {
            if let url = self.coordinator?.fileURL(forTrackID: id) {
                item.setString(url.absoluteString, forType: .fileURL)
            }
        }
        return item
    }

    // MARK: - Drag-reorder (intra-table)

    /// Validate a drop: a reorder from this table, or songs from another one.
    @objc func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let kind = self.dropKind(for: info, in: tableView)
        guard kind != .refuse else { return [] }
        // Only allow drop between rows, not onto a row.
        if dropOperation == .on {
            tableView.setDropRow(row, dropOperation: .above)
        }
        return kind == .reorder ? .move : .copy
    }

    /// Accept the drop: `onMove` with SwiftUI-style indices for a reorder,
    /// `onDropTracks` with the dropped IDs for songs from another table.
    @objc func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let trackIDs = TrackDropRules.trackIDs(in: info.draggingPasteboard)
        switch self.dropKind(for: info, in: tableView) {
        case .reorder:
            // Each dragged track ID's current index in the snapshot.
            let sourceIndices = IndexSet(trackIDs.compactMap { self.row(forItemIdentifier: $0) }.filter { $0 >= 0 })
            guard let onMove = self.onMove, !sourceIndices.isEmpty else { return false }
            onMove(sourceIndices, row)
            return true

        case .insert:
            guard let onDropTracks = self.onDropTracks else { return false }
            onDropTracks(trackIDs, row)
            return true

        case .refuse:
            return false
        }
    }

    private func dropKind(for info: any NSDraggingInfo, in tableView: NSTableView) -> TrackDropRules.Kind {
        TrackDropRules.kind(
            fromThisTable: info.draggingSource as? NSTableView === tableView,
            fromThisApp: info.draggingSource != nil,
            canReorder: self.onMove != nil,
            acceptsTracks: self.onDropTracks != nil,
            hasTrackIDs: !TrackDropRules.trackIDs(in: info.draggingPasteboard).isEmpty
        )
    }
}

// MARK: - TrackDropRules

/// What a drop on a songs table does (#709). Pure, so the rules are testable
/// without a live drag session.
enum TrackDropRules {
    enum Kind: Equatable {
        /// Rows dragged within this table: move them.
        case reorder
        /// Songs dragged from another table in the app: insert them.
        case insert
        /// Anything else, including text dragged in from another app.
        case refuse
    }

    static func kind(
        fromThisTable: Bool,
        fromThisApp: Bool,
        canReorder: Bool,
        acceptsTracks: Bool,
        hasTrackIDs: Bool
    ) -> Kind {
        guard hasTrackIDs else { return .refuse }
        // A drag inside the table only ever reorders. It never adds copies,
        // which is what the playlist overlay used to do with it (#709).
        if fromThisTable {
            return canReorder ? .reorder : .refuse
        }
        // `draggingSource` is nil for a drag from another app, whose plain
        // text could otherwise parse as track IDs.
        return fromThisApp && acceptsTracks ? .insert : .refuse
    }

    /// The track IDs on a drag's pasteboard, one per item, as
    /// `pasteboardWriterForRow` writes them. Items that are not IDs are skipped.
    static func trackIDs(in pasteboard: NSPasteboard) -> [Int64] {
        (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .string) }.compactMap { Int64($0) }
    }
}

// MARK: - TrackTable + dragging

extension TrackTable {
    /// Sets the drag masks and the drop registration for the current handlers.
    /// Called from `makeNSView` and from every `updateNSView`, because a
    /// playlist's handlers can arrive after the table is built (#709). Cheap
    /// and idempotent.
    static func configureDragging(_ tableView: NSTableView, canReorder: Bool, acceptsDrops: Bool) {
        // Move for a reorder, copy for a drop on a sidebar playlist row.
        tableView.setDraggingSourceOperationMask(canReorder ? [.move, .copy] : .copy, forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        let registered = tableView.registeredDraggedTypes.contains(.string)
        if canReorder || acceptsDrops {
            if !registered {
                tableView.registerForDraggedTypes([.string])
            }
        } else if registered {
            tableView.unregisterDraggedTypes()
        }
    }
}
