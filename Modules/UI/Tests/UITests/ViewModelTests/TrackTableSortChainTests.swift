import AppKit
import Persistence
import SwiftUI
import Testing
@testable import UI

// MARK: - TrackTableSortChainTests (ADR-093 slice 1)

/// `NSTableView` accumulates a sort chain for free: a header click prepends
/// the clicked column's descriptor and keeps the rest behind it. The table
/// then wrote a one-element array back over that list on every update, so two
/// keys was the ceiling and a third click pushed the oldest out.
///
/// These drive the coordinator's two real sort functions in the order
/// `updateNSView` does. The header click itself cannot be synthesised
/// host-less, so `click` reproduces AppKit's prepend-and-dedupe.
@Suite("TrackTable sort chains")
@MainActor
struct TrackTableSortChainTests {
    /// Holds the sort order the table's binding writes, so a test can read it
    /// back the way SwiftUI would.
    @MainActor
    private final class SortBox {
        var order: [KeyPathComparator<TrackRow>] = []
    }

    private func makeActions() -> TrackContextMenuActions {
        let noop: (Track) -> Void = { _ in }
        return TrackContextMenuActions(
            playNow: noop,
            playSingle: noop,
            playAlbum: noop,
            shuffleAlbum: noop,
            playArtist: noop,
            playNext: { _ in },
            addToQueue: { _ in },
            addToPlaylist: { _, _ in },
            newPlaylistFromSelection: { _ in },
            love: { _ in },
            goToArtist: { _ in },
            goToAlbum: { _ in },
            showInFinder: noop,
            rescanFile: noop,
            getInfo: { _ in },
            identify: noop,
            removeFromLibrary: { _ in },
            deleteFromDisk: { _ in },
            copy: { _ in },
            toggleShuffle: { _, _ in },
            computeReplayGain: { _ in },
            rate: { _, _ in },
            removeFromPlaylist: nil,
            editLyrics: nil,
            fetchLyricsFromLRClib: nil
        )
    }

    private func makeCoordinator(_ box: SortBox) -> TrackTableCoordinator {
        var selection = Set<Track.ID>()
        let table = TrackTable(
            rows: [],
            rowsVersion: 0,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            sortOrder: Binding(get: { box.order }, set: { box.order = $0 }),
            nowPlayingTrackID: nil,
            sortable: true,
            playlistNodes: [],
            actions: self.makeActions(),
            scrollRequest: 0,
            scrollTargetTrackID: nil,
            onMove: nil
        )
        let coordinator = TrackTableCoordinator(parent: table)
        let tableView = NSTableView()
        for key in Self.columnKeys {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            tableView.addTableColumn(column)
        }
        coordinator.tableView = tableView
        return coordinator
    }

    /// Real sort keys, as `TrackTable.comparator(from:)` maps them. The Year
    /// column's key is `yearText`, not `year`; an unmappable key is dropped on
    /// the way to a comparator, which is correct and would quietly shorten a
    /// chain built from invented names.
    private static let columnKeys = ["trackNumber", "albumName", "artistName", "title", "yearText", "playCount"]

    /// What AppKit does on a header click: the clicked column's descriptor
    /// goes to the front, the rest keep their order behind it, deduped by key.
    private func click(_ key: String, on tableView: NSTableView, ascending: Bool = true) {
        var rest = tableView.sortDescriptors.filter { $0.key != key }
        rest.insert(NSSortDescriptor(key: key, ascending: ascending), at: 0)
        tableView.sortDescriptors = rest
    }

    /// One click, the way `updateNSView` sequences it: read what AppKit built,
    /// then write the resulting order back to the table.
    private func clickAndSync(
        _ key: String,
        _ coordinator: TrackTableCoordinator,
        ascending: Bool = true
    ) {
        guard let tableView = coordinator.tableView else { return }
        self.click(key, on: tableView, ascending: ascending)
        coordinator.handleSortDescriptorsDidChange(in: tableView)
        coordinator.syncSortIfNeeded(sortOrder: coordinator.parent.sortOrder)
    }

    private func keys(_ tableView: NSTableView) -> [String] {
        tableView.sortDescriptors.compactMap(\.key)
    }

    private func keys(_ order: [KeyPathComparator<TrackRow>]) -> [String] {
        order.compactMap { TrackTable.sortKey(for: $0) }
    }

    // MARK: - The round trip

    @Test("what the table writes back is what it would read")
    func roundTrip() throws {
        let box = SortBox()
        let coordinator = self.makeCoordinator(box)
        let tableView = try #require(coordinator.tableView)

        self.clickAndSync("trackNumber", coordinator)
        self.clickAndSync("albumName", coordinator)
        self.clickAndSync("artistName", coordinator)

        // Reading the table again must produce the same order it was just
        // given. A write-back that differs from the read is the original bug.
        let beforeRead = self.keys(box.order)
        coordinator.handleSortDescriptorsDidChange(in: tableView)
        #expect(self.keys(box.order) == beforeRead)
        #expect(self.keys(tableView) == beforeRead)
    }

    // MARK: - Composing

    @Test("a plain click sorts by that column, whatever was clicked before")
    func plainClickReplacesTheChain() throws {
        let box = SortBox()
        let coordinator = self.makeCoordinator(box)
        let tableView = try #require(coordinator.tableView)

        // The reported bug: a Title click stayed in the chain and outranked
        // the album grouping of a later Artist click, invisibly.
        self.clickAndSync("title", coordinator)
        self.clickAndSync("artistName", coordinator)

        #expect(self.keys(box.order) == ["artistName", "albumName", "discNumber", "trackNumber"])
        #expect(!self.keys(box.order).contains("title"), "the earlier click must not survive a plain click")
        #expect(self.keys(box.order) == self.keys(tableView))
    }

    @Test("the whole chain reaches the table, not just its head")
    func wholeChainReachesTheTable() throws {
        let box = SortBox()
        let coordinator = self.makeCoordinator(box)
        let tableView = try #require(coordinator.tableView)

        self.clickAndSync("artistName", coordinator)

        // The original bug: the table kept only the head, so the next click
        // composed against a truncated list.
        #expect(self.keys(tableView).count > 1)
        #expect(self.keys(box.order) == self.keys(tableView))
    }

    @Test("a chain never outgrows the cap")
    func chainIsCapped() throws {
        let box = SortBox()
        let coordinator = self.makeCoordinator(box)
        let tableView = try #require(coordinator.tableView)

        // Genre is the longest chain: genre, artist, album, disc, track.
        self.clickAndSync("genre", coordinator)

        #expect(box.order.count == TrackTable.maxSortKeys)
        #expect(self.keys(tableView).count <= TrackTable.maxSortKeys)
    }

    @Test("a direction change replaces the key rather than adding one")
    func directionChangeDoesNotDuplicate() throws {
        let box = SortBox()
        let coordinator = self.makeCoordinator(box)
        let tableView = try #require(coordinator.tableView)

        self.clickAndSync("albumName", coordinator, ascending: true)
        self.clickAndSync("albumName", coordinator, ascending: false)

        let keys = self.keys(box.order)
        #expect(keys.first == "albumName")
        #expect(keys.filter { $0 == "albumName" }.count == 1, "one key, not one per direction")
        #expect(tableView.sortDescriptors.first?.ascending == false)
    }

    // MARK: - Clearing

    @Test("an empty order still clears the header arrow")
    func emptyOrderClearsTheArrow() throws {
        let box = SortBox()
        let coordinator = self.makeCoordinator(box)
        let tableView = try #require(coordinator.tableView)

        self.clickAndSync("albumName", coordinator)
        try #require(!tableView.sortDescriptors.isEmpty)

        coordinator.syncSortIfNeeded(sortOrder: [])
        #expect(tableView.sortDescriptors.isEmpty)
    }

    @Test("the write-back does not re-enter the reader")
    func writeBackDoesNotReenter() throws {
        let box = SortBox()
        let coordinator = self.makeCoordinator(box)
        _ = try #require(coordinator.tableView)

        self.clickAndSync("albumName", coordinator)
        self.clickAndSync("artistName", coordinator)
        let composed = self.keys(box.order)

        // Assigning sortDescriptors fires the delegate callback; the guard
        // must stop it running the cap and dedupe against its own output.
        coordinator.syncSortIfNeeded(sortOrder: box.order)
        #expect(self.keys(box.order) == composed)
    }
}
