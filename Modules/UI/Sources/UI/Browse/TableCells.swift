import AppKit

// MARK: - TableCells

/// The text cell and the cover art cell that the four song tables share:
/// the local songs table, History, Subsonic and Jellyfin (#695). Each table
/// keeps its own reuse identifiers, so a cell is never reused across tables.
@MainActor
enum TableCells {
    /// A reused text cell for `identifier`, or a new one: a single-line label
    /// inset 4 pt on each side, centred vertically, truncated at the tail.
    static func text(
        _ identifier: NSUserInterfaceItemIdentifier,
        in tableView: NSTableView,
        truncatesLastVisibleLine: Bool = false
    ) -> NSTableCellView {
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            return reused
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        if truncatesLastVisibleLine {
            field.cell?.truncatesLastVisibleLine = true
        }
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// A reused cover art cell for `identifier`, or a new one.
    static func coverArt(_ identifier: NSUserInterfaceItemIdentifier, in tableView: NSTableView) -> CoverArtTableCell {
        tableView.makeView(withIdentifier: identifier, owner: nil) as? CoverArtTableCell
            ?? CoverArtTableCell(identifier: identifier)
    }
}

// MARK: - CoverArtTableCell

/// `NSTableCellView` for a cover art column.
///
/// The image sits in a square with rounded corners that fills the row height,
/// less 2 pt above and below, centred horizontally. Each table supplies the
/// load, so the cell knows nothing about where the image comes from. A new
/// `configure` cancels the load in flight, so a reused cell never shows the
/// previous row's cover.
final class CoverArtTableCell: NSTableCellView {
    /// Loads the image for one row. Runs in a task the cell cancels on reuse.
    typealias Load = @MainActor @Sendable () async -> NSImage?

    private let imageContainer = NSView()
    private let artImageView = NSImageView()
    private var loadTask: Task<Void, Never>?

    /// The image the cell shows now; nil while a load runs or without art.
    var shownImage: NSImage? {
        self.artImageView.image
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        // The container fills the cell and clips the image.
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

    /// Clears the cell, sets its VoiceOver label, and starts `load` if given.
    ///
    /// - Parameters:
    ///   - title: the row's title, spoken as "<title> artwork".
    ///   - hasArt: whether the row names a cover. It decides the label, even
    ///     when there is no `load` to fetch the cover with.
    ///   - load: fetches the image; nil leaves the cell empty.
    func configure(title: String, hasArt: Bool, load: Load?) {
        self.loadTask?.cancel()
        self.artImageView.image = nil
        setAccessibilityLabel(hasArt ? L10n.string("\(title) artwork") : L10n.string("No artwork"))
        guard let load else { return }
        self.loadTask = Task { @MainActor [weak self] in
            let image = await load()
            guard !Task.isCancelled else { return }
            self?.artImageView.image = image
        }
    }
}
