import AppKit
import Foundation
import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - Row model

/// Decorated row for the Subsonic songs NSTableView, carrying every
/// field available from `Song` plus live star/rating state from the
/// `SubsonicAnnotationCoordinator`.
struct SubsonicSongTableRow: Identifiable {
    let song: Song
    let starred: Bool
    let rating: Int

    var id: String {
        self.song.id
    }

    var title: String {
        self.song.title
    }

    var artist: String {
        self.song.artist ?? ""
    }

    var album: String {
        self.song.album ?? ""
    }

    var year: Int {
        self.song.year ?? 0
    }

    var genre: String {
        self.song.genre ?? ""
    }

    var duration: Int {
        self.song.duration ?? 0
    }

    var trackNumber: Int {
        self.song.track ?? 0
    }

    var discNumber: Int {
        self.song.discNumber ?? 0
    }

    var bitrate: Int {
        self.song.bitRate ?? 0
    }

    var coverArtEntityID: String? {
        self.song.coverArt
    }
}

// MARK: - Actions bag

/// Closures wired from `SubsonicSongsView` into the table and its coordinator.
struct SubsonicSongTableActions {
    /// Play the songs list starting at `index`.
    let playNow: (Int) -> Void
    /// Request the next page of songs.
    let loadMore: () -> Void
    /// Toggle the star state for the given song ID.
    let toggleStar: (String) -> Void
    /// Set a 0–5 rating for the given song ID.
    let setRating: (String, Int) -> Void
}

// MARK: - NSViewRepresentable

/// NSTableView-backed songs list for a Subsonic server, mirroring the
/// appearance and behaviour of the local library's `TrackTable`.
struct SubsonicSongTable: NSViewRepresentable {
    let serverID: UUID
    let rows: [SubsonicSongTableRow]
    let isLoading: Bool
    let hasMorePages: Bool
    let coverArtProvider: SubsonicCoverArtProvider?
    let actions: SubsonicSongTableActions

    typealias NSViewType = NSScrollView

    func makeCoordinator() -> SubsonicSongTableCoordinator {
        SubsonicSongTableCoordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let tableView = NSTableView()
        tableView.style = .fullWidth
        tableView.rowSizeStyle = .custom
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.autosaveName = "bocan.subsonicSongsTable.v1"
        tableView.autosaveTableColumns = true

        Self.addColumns(to: tableView)
        Self.buildHeaderMenu(for: tableView, coordinator: context.coordinator)

        let dataSource = SubsonicSongDiffableDataSource(
            tableView: tableView
        ) { tv, col, _, id in
            context.coordinator.cellView(for: col, songID: id, in: tv) ?? NSTableCellView()
        }
        dataSource.coordinator = context.coordinator
        tableView.dataSource = dataSource
        tableView.delegate = context.coordinator

        tableView.target = context.coordinator
        tableView.doubleAction = #selector(SubsonicSongTableCoordinator.doubleClickAction(_:))

        // Build context menu
        let contextMenu = NSMenu()
        contextMenu.delegate = context.coordinator
        tableView.menu = contextMenu

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.dataSource = dataSource

        // Observe scroll position to trigger pagination.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(SubsonicSongTableCoordinator.scrollViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let dataSource = context.coordinator.dataSource else { return }

        // Keep the cell-lookup dictionary current (star/rating may have changed).
        context.coordinator.updateRows(self.rows)

        // Only rebuild the snapshot when the *set* of song IDs changes.
        let newIDSet = Set(self.rows.map(\.id))
        let currentIDSet = Set(context.coordinator.lastAppliedIDs)
        guard newIDSet != currentIDSet else { return }

        // Preserve the existing sort order for already-loaded songs; append
        // new songs at the end.
        let keepIDs = context.coordinator.lastAppliedIDs.filter { newIDSet.contains($0) }
        let addIDs = self.rows.filter { !currentIDSet.contains($0.id) }.map(\.id)
        let orderedIDs = keepIDs + addIDs
        context.coordinator.lastAppliedIDs = orderedIDs

        var snap = NSDiffableDataSourceSnapshot<Int, String>()
        snap.appendSections([0])
        snap.appendItems(orderedIDs)
        dataSource.apply(snap, animatingDifferences: context.coordinator.hasAppliedInitialSnapshot)
        context.coordinator.hasAppliedInitialSnapshot = true
    }

    // MARK: Column definitions

    private struct ColDef {
        let rawID: String
        let title: String
        let min: CGFloat
        let ideal: CGFloat
        let max: CGFloat
        let sortKey: String?
        var hidden = false
    }

    private static let colDefs: [ColDef] = [
        ColDef(rawID: "art", title: "Art", min: 18, ideal: 32, max: 44, sortKey: nil),
        ColDef(rawID: "title", title: "Title", min: 140, ideal: 220, max: 2000, sortKey: "title"),
        ColDef(rawID: "artist", title: "Artist", min: 80, ideal: 160, max: 2000, sortKey: "artist"),
        ColDef(rawID: "album", title: "Album", min: 80, ideal: 160, max: 2000, sortKey: "album"),
        ColDef(rawID: "year", title: "Year", min: 40, ideal: 56, max: 80, sortKey: "year"),
        ColDef(rawID: "genre", title: "Genre", min: 60, ideal: 120, max: 2000, sortKey: "genre"),
        ColDef(rawID: "duration", title: "Length", min: 48, ideal: 60, max: 72, sortKey: "duration"),
        ColDef(rawID: "trackNum", title: "Track", min: 28, ideal: 40, max: 56, sortKey: "trackNum"),
        ColDef(rawID: "bitrate", title: "Bitrate", min: 56, ideal: 72, max: 96, sortKey: "bitrate", hidden: true),
        ColDef(rawID: "rating", title: "Rating", min: 52, ideal: 64, max: 72, sortKey: "rating"),
        ColDef(rawID: "starred", title: "\u{2605}", min: 24, ideal: 32, max: 40, sortKey: "starred"),
    ]

    private static func addColumns(to tableView: NSTableView) {
        let autosaveName = tableView.autosaveName ?? ""
        for def in self.colDefs {
            let colID = NSUserInterfaceItemIdentifier("scol.\(def.rawID)")
            let col = NSTableColumn(identifier: colID)
            col.title = def.title
            col.headerCell.title = def.title
            col.headerCell.setAccessibilityLabel(def.title)
            col.minWidth = def.min
            col.width = def.ideal
            col.maxWidth = def.max
            if let key = def.sortKey {
                col.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            }
            // Restore persisted visibility, falling back to the spec default.
            let visKey = "bocan.col.hidden.\(autosaveName).scol.\(def.rawID)"
            col.isHidden = UserDefaults.standard.object(forKey: visKey) != nil
                ? UserDefaults.standard.bool(forKey: visKey)
                : def.hidden
            tableView.addTableColumn(col)
        }
    }

    private static func buildHeaderMenu(
        for tableView: NSTableView,
        coordinator: SubsonicSongTableCoordinator
    ) {
        let menu = NSMenu()
        for col in tableView.tableColumns {
            let item = NSMenuItem(
                title: col.title,
                action: #selector(SubsonicSongTableCoordinator.toggleColumnVisibility(_:)),
                keyEquivalent: ""
            )
            item.representedObject = col
            item.state = col.isHidden ? .off : .on
            item.target = coordinator
            menu.addItem(item)
        }
        tableView.headerView?.menu = menu
    }
}

// MARK: - Diffable data source

@MainActor
final class SubsonicSongDiffableDataSource: NSTableViewDiffableDataSource<Int, String> {
    weak var coordinator: SubsonicSongTableCoordinator?

    @objc func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange _: [NSSortDescriptor]
    ) {
        MainActor.assumeIsolated {
            self.coordinator?.handleSortChanged(in: tableView)
        }
    }
}

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
    var lastRowDensity = UserDefaults.standard.string(forKey: "appearance.rowDensity") ?? "regular"

    weak var tableView: NSTableView?
    var dataSource: SubsonicSongDiffableDataSource?

    private var paginationCooldown = false

    init(parent: SubsonicSongTable) {
        self.parent = parent
    }

    func updateRows(_ newRows: [SubsonicSongTableRow]) {
        self.rows = newRows
        self.rowsByID = Dictionary(
            newRows.map { ($0.id, $0) },
            uniquingKeysWith: { _, new in new }
        )
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

    // swiftlint:disable cyclomatic_complexity
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

    // swiftlint:enable cyclomatic_complexity

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch UserDefaults.standard.string(forKey: "appearance.rowDensity") {
        case "compact": 22
        case "spacious": 36
        default: 28
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
        case "title": self.rows.sort { asc ? $0.title < $1.title : $0.title > $1.title }
        case "artist": self.rows.sort { asc ? $0.artist < $1.artist : $0.artist > $1.artist }
        case "album": self.rows.sort { asc ? $0.album < $1.album : $0.album > $1.album }
        case "year": self.rows.sort { asc ? $0.year < $1.year : $0.year > $1.year }
        case "genre": self.rows.sort { asc ? $0.genre < $1.genre : $0.genre > $1.genre }
        case "duration": self.rows.sort { asc ? $0.duration < $1.duration : $0.duration > $1.duration }
        case "trackNum": self.rows.sort { asc ? $0.trackNumber < $1.trackNumber : $0.trackNumber > $1.trackNumber }
        case "bitrate": self.rows.sort { asc ? $0.bitrate < $1.bitrate : $0.bitrate > $1.bitrate }
        case "rating": self.rows.sort { asc ? $0.rating < $1.rating : $0.rating > $1.rating }
        case "starred": self.rows.sort { asc ? (!$0.starred && $1.starred) : ($0.starred && !$1.starred) }
        default: return
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

// MARK: - SubsonicCoverArtCell

/// `NSTableCellView` that asynchronously loads cover art for a Subsonic entity.
///
/// First resolves the `coverArtURL` via `SubsonicCoverArtProvider`, then
/// downloads and caches the `NSImage`.  Cancels in-flight work when reused.
final class SubsonicCoverArtCell: NSTableCellView {
    private let imageContainer = NSView()
    private let artImageView = NSImageView()
    private var loadTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("sArtCell")

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
        provider: SubsonicCoverArtProvider?,
        serverID: UUID,
        entityID: String?,
        seed: Int,
        title: String
    ) {
        self.loadTask?.cancel()
        self.artImageView.image = nil
        setAccessibilityLabel(entityID == nil ? "No artwork" : "\(title) artwork")
        guard let provider, let entityID else { return }
        self.loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let url = try? await provider.coverArtURL(
                serverID: serverID,
                entityID: entityID,
                size: 64
            ) else { return }
            guard !Task.isCancelled else { return }
            let img = await SubsonicImageCache.shared.image(url: url)
            guard !Task.isCancelled else { return }
            self.artImageView.image = img
        }
    }
}

// MARK: - SubsonicStarButtonCell

/// `NSTableCellView` for the star (★) column.
///
/// Manages its own optimistic visual state so taps feel instant, without
/// needing a full SwiftUI re-render cycle.
final class SubsonicStarButtonCell: NSTableCellView {
    private static let starredColor = NSColor.systemYellow
    private static let unstarredColor = NSColor.tertiaryLabelColor

    private let button = NSButton(frame: .zero)
    private var songID: String?
    private var isStarred = false
    private var onToggle: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("sStarCell")
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

    func configure(starred: Bool, action: @escaping (String) -> Void, songID: String) {
        self.songID = songID
        self.isStarred = starred
        self.onToggle = action
        self.updateButton()
    }

    private func updateButton() {
        let bodyFont = NSFont.preferredFont(forTextStyle: .body)
        let color: NSColor = self.isStarred ? Self.starredColor : Self.unstarredColor
        let attrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: color]
        self.button.attributedTitle = NSAttributedString(string: "\u{2605}", attributes: attrs)
        self.button.setAccessibilityLabel(self.isStarred ? "Starred" : "Not starred")
        self.button.toolTip = self.isStarred ? "Starred — click to unstar" : "Click to star"
    }

    @objc private func tapped() {
        guard let id = songID else { return }
        self.isStarred.toggle()
        self.updateButton()
        self.onToggle?(id)
    }
}

// MARK: - SubsonicImageCache

/// Thread-safe NSImage cache for Subsonic cover art URLs.
actor SubsonicImageCache {
    static let shared = SubsonicImageCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        return c
    }()

    /// Returns a decoded `NSImage` for `url`, downloading it if not cached.
    func image(url: URL) async -> NSImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = NSImage(data: data) else { return nil }
        self.cache.setObject(img, forKey: key)
        return img
    }
}
