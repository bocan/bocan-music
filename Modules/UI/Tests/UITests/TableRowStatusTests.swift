import AppKit
import Persistence
import SwiftUI
import Testing
@testable import UI

// MARK: - TableRowStatusTests

/// A table row has no VoiceOver label of its own, so one cell speaks the
/// row's status (#300, #694). These build real table cells, so they live
/// outside `ViewModelTests`: the host-less Xcode bundle cannot create them.
@MainActor
@Suite("Table row status is spoken by one cell")
struct TableRowStatusTests {
    private static let trackID: Int64 = 1

    private func makeNoopActions() -> TrackContextMenuActions {
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

    /// A coordinator holding one song, and a table with an art, a Title and
    /// an Artist column.
    private func makeTrackTable(nowPlaying: Bool) -> (TrackTableCoordinator, NSTableView) {
        let track = Track(
            id: Self.trackID,
            fileURL: "file:///tmp/inMyLife.mp3",
            fileFormat: "mp3",
            duration: 167.0,
            title: "In My Life",
            addedAt: 0,
            updatedAt: 0
        )
        let row = TrackRow(track: track, artistName: "The Beatles", albumName: "Rubber Soul")
        let table = TrackTable(
            rows: [],
            rowsVersion: 0,
            selection: .constant([]),
            sortOrder: .constant([]),
            nowPlayingTrackID: nowPlaying ? .some(Self.trackID) : nil,
            sortable: false,
            playlistNodes: [],
            actions: self.makeNoopActions(),
            scrollRequest: 0,
            scrollTargetTrackID: nil,
            onMove: nil
        )
        let coordinator = TrackTableCoordinator(parent: table)
        coordinator.updateRows([row])

        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        for id in [NSUserInterfaceItemIdentifier.albumArt, .title, .artist] {
            let column = NSTableColumn(identifier: id)
            column.width = 150
            tableView.addTableColumn(column)
        }
        return (coordinator, tableView)
    }

    private func spoken(
        _ column: NSUserInterfaceItemIdentifier,
        _ coordinator: TrackTableCoordinator,
        _ tableView: NSTableView
    ) throws -> String? {
        let tableColumn = try #require(tableView.tableColumn(withIdentifier: column))
        let cell = coordinator.cellView(for: tableColumn, trackID: Self.trackID, in: tableView)
        return cell?.accessibilityLabel()
    }

    @Test("The playing row says so on its Title cell and on no other cell")
    func nowPlayingIsOnTheTitleCell() throws {
        let (coordinator, tableView) = self.makeTrackTable(nowPlaying: true)
        #expect(try self.spoken(.title, coordinator, tableView) == "Now playing, Title: In My Life")
        #expect(try self.spoken(.artist, coordinator, tableView) == "Artist: The Beatles")
    }

    @Test("A row that is not playing does not say Now playing")
    func otherRowsDoNotSayNowPlaying() throws {
        let (coordinator, tableView) = self.makeTrackTable(nowPlaying: false)
        #expect(try self.spoken(.title, coordinator, tableView) == "Title: In My Life")
    }

    @Test("With Title hidden, the first visible text column speaks the status, never the art")
    func hiddenTitleMovesTheStatus() throws {
        let (coordinator, tableView) = self.makeTrackTable(nowPlaying: true)
        let titleColumn = try #require(tableView.tableColumn(withIdentifier: .title))
        titleColumn.isHidden = true
        #expect(try self.spoken(.artist, coordinator, tableView) == "Now playing, Artist: The Beatles")
    }

    @Test("Hiding Title rebuilds the playing row, so the status moves at once")
    func togglingTitleRebuildsTheRow() throws {
        let (coordinator, tableView) = self.makeTrackTable(nowPlaying: true)
        let dataSource = TrackDiffableDataSource(tableView: tableView) { table, column, _, id in
            MainActor.assumeIsolated {
                coordinator.cellView(for: column, trackID: id, in: table) ?? NSTableCellView()
            }
        }
        coordinator.tableView = tableView
        coordinator.dataSource = dataSource
        coordinator.applied.nowPlayingID = Self.trackID
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int64>()
        snapshot.appendSections([0])
        snapshot.appendItems([Self.trackID])
        dataSource.apply(snapshot, animatingDifferences: false)

        let artistIndex = tableView.column(withIdentifier: .artist)
        let before = tableView.view(atColumn: artistIndex, row: 0, makeIfNecessary: true)
        #expect(before?.accessibilityLabel() == "Artist: The Beatles")

        let item = NSMenuItem()
        item.representedObject = try #require(tableView.tableColumn(withIdentifier: .title))
        coordinator.toggleColumnVisibility(item)

        let after = tableView.view(atColumn: artistIndex, row: 0, makeIfNecessary: true)
        #expect(after?.accessibilityLabel() == "Now playing, Artist: The Beatles")
    }

    @Test("A listen whose file is missing says so on its Title cell only")
    func missingFileIsSpoken() throws {
        let many: ([PlayHistoryRow.Key]) -> Void = { _ in }
        let one: (PlayHistoryRow.Key) -> Void = { _ in }
        let id: (Int64) -> Void = { _ in }
        let none: () -> Void = {}
        let actions = HistoryTableActions(
            playNow: one,
            playNext: many,
            addToQueue: many,
            goToArtist: id,
            goToAlbum: id,
            showInFinder: one,
            getInfo: many,
            loadMore: none
        )
        let table = HistoryTable(rows: [], rowsVersion: 0, hasMore: false, isLoading: false, actions: actions)
        let coordinator = HistoryTableCoordinator(parent: table)
        let missing = PlayHistoryRow(
            source: .local, rowID: 1, playedAt: 0, trackID: 1, title: "Gone", artistName: "Band", isMissing: true
        )
        let present = PlayHistoryRow(source: .local, rowID: 2, playedAt: 0, trackID: 2, title: "Here", artistName: "Band")
        coordinator.updateRows([missing, present])

        let tableView = NSTableView()
        for rawID in ["title", "artist"] {
            let column = NSTableColumn(identifier: HistoryTable.columnID(rawID))
            column.title = rawID == "title" ? "Title" : "Artist"
            tableView.addTableColumn(column)
        }
        let titleColumn = try #require(tableView.tableColumn(withIdentifier: HistoryTable.columnID("title")))
        let artistColumn = try #require(tableView.tableColumn(withIdentifier: HistoryTable.columnID("artist")))

        let title = coordinator.cellView(for: titleColumn, key: missing.id, in: tableView)
        let artist = coordinator.cellView(for: artistColumn, key: missing.id, in: tableView)
        let other = coordinator.cellView(for: titleColumn, key: present.id, in: tableView)
        #expect(title?.accessibilityLabel() == "Title: Gone, file missing")
        #expect(artist?.accessibilityLabel() == "Artist: Band")
        #expect(other?.accessibilityLabel() == "Title: Here")
    }
}
