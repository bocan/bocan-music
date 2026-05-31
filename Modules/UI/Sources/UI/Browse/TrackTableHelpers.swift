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
        self.checkbox.setAccessibilityLabel("Exclude \(self.trackTitle) from shuffle")
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
        self.button.setAccessibilityLabel(row.loved ? "Loved" : "Not loved")
        self.button.toolTip = row.loved ? "Loved — click to unlove" : "Click to love"
    }

    @objc private func tapped() {
        guard let track else { return }
        self.onToggle?([track])
    }
}

// MARK: - CoverArtImageCell

/// `NSTableCellView` for the album-art column.
///
/// The image view is constrained as a square that fills the row height
/// (minus 2 pt padding on each side).  When `artPath` changes the cell
/// cancels any in-flight load and starts a fresh `Task` via `ArtworkLoader`.
final class CoverArtImageCell: NSTableCellView {
    private let imageContainer = NSView()
    private let artImageView = NSImageView()
    private var loadTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("artCell.albumArt")

        // Container fills the cell and clips the image.
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
            // Container: square, vertically inset 2 pt, horizontally centred.
            self.imageContainer.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            self.imageContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            self.imageContainer.widthAnchor.constraint(equalTo: self.imageContainer.heightAnchor),
            self.imageContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Image fills the container.
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

    func configure(artPath: String?, trackTitle: String) {
        self.loadTask?.cancel()
        self.artImageView.image = nil
        setAccessibilityLabel(artPath == nil ? "No artwork" : "\(trackTitle) artwork")
        guard let path = artPath else { return }
        self.loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Track rows show art at roughly row height (~36 pt); request a
            // matching thumbnail rather than decoding the full-resolution cover.
            let img = await ArtworkLoader.shared.image(at: path, maxDimensionPoints: 40)
            guard !Task.isCancelled else { return }
            self.artImageView.image = img
        }
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
