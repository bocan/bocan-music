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
        Self.id(serverID: self.serverID, songID: self.song.id)
    }

    /// Composes the per-server row identifier from its parts. Used by the Songs
    /// and detail views to map the now-playing Subsonic stream onto a row ID.
    static func id(serverID: UUID, songID: String) -> String {
        "\(serverID.uuidString)::\(songID)"
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
    /// The owner's counter for `rows` (#455): `updateNSView` walks the rows
    /// only when this moved since the last apply. Rows are derived in the
    /// view from a song list and the annotation overrides, so the version
    /// folds both counters; see `rowsVersion(songs:annotations:)`.
    /// Deliberately has no default: a caller that left it out would render
    /// its first rows and then never react to another change (#454).
    let rowsVersion: Int
    let isLoading: Bool
    let hasMorePages: Bool
    let coverArtProvider: SubsonicCoverArtProvider?
    let showsSource: Bool
    /// Row ID of the currently-playing Subsonic stream, or `nil`. When this
    /// changes the table moves its selection onto that row, mirroring the local
    /// library's `syncSelectionToNowPlaying`.
    var nowPlayingRowID: String?
    let actions: SubsonicSongTableActions

    typealias NSViewType = NSScrollView

    /// The rows version for a table whose rows are derived from a song list
    /// counter plus the annotation coordinator's override counter. Both only
    /// ever increase, so their sum moves whenever either input changed.
    static func rowsVersion(songs: Int, annotations: SubsonicAnnotationCoordinator?) -> Int {
        songs &+ (annotations?.overridesVersion ?? 0)
    }

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
        tableView.setAccessibilityIdentifier(A11y.TracksTable.subsonicTable)
        tableView.style = .fullWidth
        tableView.rowSizeStyle = .custom
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let autosaveName = "bocan.subsonicSongsTable.v1"
        Self.addColumns(to: tableView, includingSource: self.showsSource, autosaveName: autosaveName)
        // Arm autosave only after the columns exist; setting `autosaveName`
        // triggers the order/width restore onto the current columns (#369,
        // same ordering bug as TrackTable).
        tableView.autosaveTableColumns = true
        tableView.autosaveName = autosaveName
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
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let dataSource = coordinator.dataSource else { return }

        // Decide what moved since the last apply (#455). The rows version
        // gates every per-row walk, so a parent re-render with unchanged rows
        // rebuilds neither the cell-lookup dictionary nor the ID sets. The
        // table keeps its own row order (a header-click sort rewrites it), so
        // the plan's ID list is compared against that order and a same-set,
        // different-order result is resolved below without a snapshot.
        // No highlight and no selection input: the now-playing row is handled
        // by `syncSelectionToNowPlaying`, which has its own change guard.
        let plan = SubsonicSongTableUpdatePlan.make(
            rowsVersion: self.rowsVersion,
            ids: { self.rows.map(\.id) },
            nowPlayingID: nil,
            selection: [],
            applied: coordinator.applied
        )
        switch plan.rowsWork {
        case .unchanged:
            break

        case .reconfigure:
            // Same rows, new content (a star or rating moved): refresh the
            // cell-lookup dictionary that the star and text cells read from.
            coordinator.updateRows(self.rows)

        case .structural:
            coordinator.updateRows(self.rows)
            // Preserve the existing order for already-loaded songs; append
            // new songs at the end. Only apply a snapshot when that changed
            // the list, so a same-set update after a sort costs no apply.
            let newIDSet = Set(plan.ids ?? [])
            let currentIDSet = Set(coordinator.applied.ids)
            let keepIDs = coordinator.applied.ids.filter { newIDSet.contains($0) }
            let addIDs = self.rows.filter { !currentIDSet.contains($0.id) }.map(\.id)
            let orderedIDs = keepIDs + addIDs
            if orderedIDs != coordinator.applied.ids {
                var snap = NSDiffableDataSourceSnapshot<Int, String>()
                snap.appendSections([0])
                snap.appendItems(orderedIDs)
                dataSource.apply(snap, animatingDifferences: coordinator.hasAppliedInitialSnapshot)
                coordinator.hasAppliedInitialSnapshot = true
            }
            coordinator.applied.ids = orderedIDs
        }
        // Remember the version; the IDs were set above in the table's order.
        coordinator.applied.rowsVersion = self.rowsVersion

        // Once the snapshot reflects the current rows, move the selection onto
        // the now-playing row when it changes.
        coordinator.syncSelectionToNowPlaying(self.nowPlayingRowID)
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
        ColDef(rawID: "art", title: L10n.string("Art"), min: 18, ideal: 32, max: 44, sortKey: nil),
        ColDef(rawID: "title", title: L10n.string("Title"), min: 140, ideal: 220, max: 2000, sortKey: "title"),
        ColDef(rawID: "artist", title: L10n.string("Artist"), min: 80, ideal: 160, max: 2000, sortKey: "artist"),
        ColDef(rawID: "album", title: L10n.string("Album"), min: 80, ideal: 160, max: 2000, sortKey: "album"),
        ColDef(rawID: "year", title: L10n.string("Year"), min: 40, ideal: 56, max: 80, sortKey: "year"),
        ColDef(rawID: "genre", title: L10n.string("Genre"), min: 60, ideal: 120, max: 2000, sortKey: "genre"),
        ColDef(rawID: "duration", title: L10n.string("Length"), min: 48, ideal: 60, max: 72, sortKey: "duration"),
        ColDef(rawID: "trackNum", title: L10n.string("Track"), min: 28, ideal: 40, max: 56, sortKey: "trackNum"),
        ColDef(rawID: "bitrate", title: L10n.string("Bitrate"), min: 56, ideal: 72, max: 96, sortKey: "bitrate", hidden: true),
        ColDef(rawID: "rating", title: L10n.string("Rating"), min: 52, ideal: 64, max: 72, sortKey: "rating"),
        ColDef(rawID: "starred", title: "\u{2605}", min: 24, ideal: 32, max: 40, sortKey: "starred"),
    ]

    /// Optional column appended only when `showsSource` is `true` — i.e. the
    /// table is rendering multi-source search results and the user needs to
    /// distinguish rows by originating server.
    private static let sourceColDef = ColDef(
        rawID: "source", title: L10n.string("Source"), min: 80, ideal: 120, max: 240, sortKey: "source"
    )

    private static func addColumns(
        to tableView: NSTableView,
        includingSource: Bool,
        autosaveName: String
    ) {
        var defs = self.colDefs
        if includingSource {
            defs.append(self.sourceColDef)
        }
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
