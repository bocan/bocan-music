import AppKit
import Foundation
import Testing
@testable import UI

// MARK: - SubsonicSongNowPlayingSelectionTests

/// Covers the per-server Songs list following the playing track: when the
/// now-playing Subsonic stream changes, the table moves its selection onto that
/// row, mirroring the local library's `TracksView.syncSelectionToNowPlaying`.
@Suite("Subsonic now-playing selection")
@MainActor
struct SubsonicSongNowPlayingSelectionTests {
    /// Builds a coordinator wired to a real `NSTableView` whose diffable data
    /// source already lists `rowIDs`, so `selectRowIndexes` resolves.
    private func makeCoordinator(rowIDs: [String]) -> SubsonicSongTableCoordinator {
        let table = SubsonicSongTable(
            rows: [],
            rowsVersion: 0,
            isLoading: false,
            hasMorePages: false,
            coverArtProvider: nil,
            showsSource: false,
            nowPlayingRowID: nil,
            actions: SubsonicSongTableActions(
                playNow: { _ in },
                loadMore: {},
                toggleStar: { _ in },
                setRating: { _, _ in }
            )
        )
        let coordinator = SubsonicSongTableCoordinator(parent: table)

        let tableView = NSTableView()
        tableView.allowsEmptySelection = true
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("scol.title")))
        let dataSource = SubsonicSongDiffableDataSource(tableView: tableView) { _, _, _, _ in NSTableCellView() }
        tableView.dataSource = dataSource

        coordinator.tableView = tableView
        coordinator.dataSource = dataSource
        coordinator.applied.ids = rowIDs

        var snap = NSDiffableDataSourceSnapshot<Int, String>()
        snap.appendSections([0])
        snap.appendItems(rowIDs)
        dataSource.apply(snap, animatingDifferences: false)

        return coordinator
    }

    @Test("Selection moves onto the now-playing row")
    func selectsNowPlayingRow() {
        let coordinator = self.makeCoordinator(rowIDs: ["a", "b", "c"])
        coordinator.syncSelectionToNowPlaying("b")
        #expect(coordinator.tableView?.selectedRow == 1)
        #expect(coordinator.lastNowPlayingRowID == "b")
    }

    @Test("A new now-playing track moves the selection again")
    func followsTrackChange() {
        let coordinator = self.makeCoordinator(rowIDs: ["a", "b", "c"])
        coordinator.syncSelectionToNowPlaying("a")
        coordinator.syncSelectionToNowPlaying("c")
        #expect(coordinator.tableView?.selectedRow == 2)
        #expect(coordinator.lastNowPlayingRowID == "c")
    }

    @Test("An unchanged now-playing track leaves the user's selection alone")
    func unchangedTrackDoesNotStompSelection() {
        let coordinator = self.makeCoordinator(rowIDs: ["a", "b", "c"])
        coordinator.syncSelectionToNowPlaying("b")
        // User manually selects a different row.
        coordinator.tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        // The same track is still playing; selection must not jump back.
        coordinator.syncSelectionToNowPlaying("b")
        #expect(coordinator.tableView?.selectedRow == 0)
    }

    @Test("A row that isn't loaded yet is a no-op but is still recorded")
    func unknownRowIsRecordedWithoutSelecting() {
        let coordinator = self.makeCoordinator(rowIDs: ["a"])
        coordinator.syncSelectionToNowPlaying("not-loaded")
        #expect(coordinator.tableView?.selectedRow == -1)
        // Recorded so a later load of the row doesn't get re-applied unexpectedly,
        // matching the "only act on change" contract.
        #expect(coordinator.lastNowPlayingRowID == "not-loaded")
    }

    @Test("Clearing the now-playing track records nil without changing selection")
    func nilNowPlayingKeepsSelection() {
        let coordinator = self.makeCoordinator(rowIDs: ["a", "b"])
        coordinator.syncSelectionToNowPlaying("a")
        coordinator.syncSelectionToNowPlaying(nil)
        #expect(coordinator.lastNowPlayingRowID == nil)
        #expect(coordinator.tableView?.selectedRow == 0)
    }

    @Test("Row ID factory matches the per-row identifier")
    func rowIDFactoryMatchesInstance() {
        let serverID = UUID()
        let composed = SubsonicSongTableRow.id(serverID: serverID, songID: "song-9")
        #expect(composed == "\(serverID.uuidString)::song-9")
    }
}

// MARK: - Source-convention wiring

@Suite("Subsonic now-playing selection wiring")
struct SubsonicSongNowPlayingWiringTests {
    private var uiSources: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/UI")
    }

    private func source(_ rel: String) throws -> String {
        try String(contentsOf: self.uiSources.appendingPathComponent(rel), encoding: .utf8)
    }

    @Test("NowPlayingViewModel publishes the playing Subsonic stream identity")
    func viewModelPublishesSubsonicIdentity() throws {
        let src = try self.source("ViewModels/NowPlayingViewModel.swift")
        #expect(src.contains("nowPlayingSubsonicSongID"), "the view model must expose the playing song ID")
        #expect(src.contains("nowPlayingSubsonicServerID"), "the view model must expose the playing server ID")
        #expect(
            src.contains("self.nowPlayingSubsonicSongID = songID"),
            "the .subsonic queue item must populate the playing song ID"
        )
    }

    @Test("The Subsonic table gates its per-row work on a rows version that every caller supplies (#455)")
    func tableAndCallersUseTheRowsVersion() throws {
        let table = try self.source("Browse/Subsonic/SubsonicSongTable.swift")
        #expect(table.contains("SubsonicSongTableUpdatePlan.make("), "the table must decide its work through the shared plan")
        #expect(table.contains("let rowsVersion: Int"), "the version is a required input, never defaulted (#454)")
        for rel in [
            "Browse/Subsonic/SubsonicSongsView.swift",
            "Browse/Subsonic/SubsonicAlbumDetailView.swift",
            "Browse/Subsonic/SubsonicArtistDetailView.swift",
        ] {
            let src = try self.source(rel)
            #expect(
                src.contains("rowsVersion: self.vm.rowsVersion") || src.contains("rowsVersion: self.search.rowsVersion"),
                "\(rel) must take the rows version from the view model that owns the rows"
            )
        }
    }

    @Test("No Subsonic view builds table rows in its body (#475)")
    func viewsDoNotDecorateRowsInBody() throws {
        // The album and artist files carry their view model alongside the
        // view, so `SubsonicSongTableRow.make` legitimately appears in them;
        // what must not appear anywhere outside the table's own file is the
        // memberwise init a view body used to map every song through.
        for rel in [
            "Browse/Subsonic/SubsonicSongsView.swift",
            "Browse/Subsonic/SubsonicAlbumDetailView.swift",
            "Browse/Subsonic/SubsonicArtistDetailView.swift",
        ] {
            let src = try self.source(rel)
            #expect(
                !src.contains("SubsonicSongTableRow("),
                "\(rel) must not map songs into rows: that runs on every re-render, including unrelated ones"
            )
            #expect(
                src.contains("rows: self.vm.rows") || src.contains("rows: self.search.rows"),
                "\(rel) must hand the table the rows its view model stores"
            )
        }
        for rel in [
            "Browse/Subsonic/SubsonicSongsViewModel.swift",
            "Browse/Subsonic/SubsonicAlbumDetailView.swift",
            "Browse/Subsonic/SubsonicArtistDetailView.swift",
            "Browse/Subsonic/SubsonicMultiSourceSearchViewModel.swift",
        ] {
            let src = try self.source(rel)
            #expect(
                src.contains("func annotationOverridesDidChange()"),
                "\(rel) must rebuild its stored rows when a star or rating moves"
            )
        }
    }

    @Test("The Subsonic Songs/detail views drive selection from the playing stream")
    func viewsPassNowPlayingRowID() throws {
        for rel in [
            "Browse/Subsonic/SubsonicSongsView.swift",
            "Browse/Subsonic/SubsonicAlbumDetailView.swift",
            "Browse/Subsonic/SubsonicArtistDetailView.swift",
        ] {
            let src = try self.source(rel)
            #expect(
                src.contains("nowPlayingRowID: self.nowPlayingRowID"),
                "\(rel) must pass the now-playing row ID into the table"
            )
        }
    }
}
