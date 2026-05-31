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
///
/// `serverID` / `serverName` are per-row so the table can present rows that
/// span multiple Subsonic servers (multi-source search results). For a
/// single-server destination view, every row shares the same pair.
struct SubsonicSongTableRow: Identifiable {
    let song: Song
    let serverID: UUID
    let serverName: String
    let starred: Bool
    let rating: Int

    /// Identifier scoped per server so multi-source rows can't collide when
    /// two servers expose the same upstream song ID.
    var id: String {
        "\(self.serverID.uuidString)::\(self.song.id)"
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
///
/// Rows now carry their own `serverID`, so this table can render either a
/// single-server destination (Songs view) or a multi-source search result
/// set. The `showsSource` flag adds a "Source" column the user can use to
/// see which server each row came from when results are aggregated.
struct SubsonicSongTable: NSViewRepresentable {
    let rows: [SubsonicSongTableRow]
    let isLoading: Bool
    let hasMorePages: Bool
    let coverArtProvider: SubsonicCoverArtProvider?
    let showsSource: Bool
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

        Self.addColumns(to: tableView, includingSource: self.showsSource)
        Self.buildHeaderMenu(for: tableView, coordinator: context.coordinator)

        let dataSource = SubsonicSongDiffableDataSource(tableView: tableView) { tv, col, _, id in
            context.coordinator.cellView(for: col, songID: id, in: tv) ?? NSTableCellView()
        }
        dataSource.coordinator = context.coordinator
        tableView.dataSource = dataSource
        tableView.delegate = context.coordinator
        // Allow streamed rows to be dragged out (e.g. into the Up Next queue) (#332).
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)

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

    /// Optional column appended only when `showsSource` is `true` — i.e. the
    /// table is rendering multi-source search results and the user needs to
    /// distinguish rows by originating server.
    private static let sourceColDef = ColDef(
        rawID: "source", title: "Source", min: 80, ideal: 120, max: 240, sortKey: "source"
    )

    private static func addColumns(to tableView: NSTableView, includingSource: Bool) {
        let autosaveName = tableView.autosaveName ?? ""
        var defs = self.colDefs
        if includingSource { defs.append(self.sourceColDef) }
        for def in defs {
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

    /// Lets a streamed song be dragged out (into the Up Next queue) by writing a
    /// `SubsonicSongDragPayload` for the row (#332).
    @objc func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        // Resolve the (Sendable) payload on the main actor, then build the AppKit
        // pasteboard item outside the isolation boundary (NSPasteboardWriting is
        // not Sendable, so it must not cross out of assumeIsolated).
        let payload: SubsonicSongDragPayload? = MainActor.assumeIsolated {
            guard let id = itemIdentifier(forRow: row) else { return nil }
            return self.coordinator?.dragPayload(forID: id)
        }
        guard let payload else { return nil }
        return SubsonicSongDrag.pasteboardItem(for: [payload])
    }
}
