import AppKit
import Foundation
import Testing
@testable import UI

// MARK: - PlaylistDragTests

/// Drag-and-drop on a playlist's songs table (#709). A drag inside the table
/// reorders it, songs dragged in from another table insert where they land,
/// and the table keeps its drop registration in step with its handlers.
@MainActor
@Suite("Playlist drag and drop")
struct PlaylistDragTests {
    // MARK: Drop rules

    @Test("A drag inside a reorderable table reorders, and never adds copies")
    func insideReorders() {
        let kind = TrackDropRules.kind(
            fromThisTable: true, fromThisApp: true, canReorder: true, acceptsTracks: true, hasTrackIDs: true
        )
        #expect(kind == .reorder)
    }

    @Test("A drag inside a table that cannot reorder (a column sort is showing) is refused")
    func insideWhileSortedIsRefused() {
        let kind = TrackDropRules.kind(
            fromThisTable: true, fromThisApp: true, canReorder: false, acceptsTracks: true, hasTrackIDs: true
        )
        #expect(kind == .refuse)
    }

    @Test("Songs from another table in the app insert")
    func fromAnotherTableInserts() {
        let kind = TrackDropRules.kind(
            fromThisTable: false, fromThisApp: true, canReorder: true, acceptsTracks: true, hasTrackIDs: true
        )
        #expect(kind == .insert)
    }

    @Test("Text from another app, a table that takes no drops, and an empty drag are refused")
    func refusals() {
        #expect(TrackDropRules.kind(
            fromThisTable: false, fromThisApp: false, canReorder: true, acceptsTracks: true, hasTrackIDs: true
        ) == .refuse)
        #expect(TrackDropRules.kind(
            fromThisTable: false, fromThisApp: true, canReorder: true, acceptsTracks: false, hasTrackIDs: true
        ) == .refuse)
        #expect(TrackDropRules.kind(
            fromThisTable: true, fromThisApp: true, canReorder: true, acceptsTracks: true, hasTrackIDs: false
        ) == .refuse)
    }

    @Test("Track IDs are read one per pasteboard item, skipping anything else")
    func readsTrackIDs() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("bocan-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let items = ["12", "not a track", "34"].map { text in
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            return item
        }
        pasteboard.writeObjects(items)
        #expect(TrackDropRules.trackIDs(in: pasteboard) == [12, 34])
    }

    // MARK: Registration

    @Test("A table built before its playlist loaded starts taking drops when the handlers arrive")
    func registrationFollowsHandlers() {
        let tableView = NSTableView()
        TrackTable.configureDragging(tableView, canReorder: false, acceptsDrops: false)
        #expect(!tableView.registeredDraggedTypes.contains(.string))

        TrackTable.configureDragging(tableView, canReorder: true, acceptsDrops: true)
        #expect(tableView.registeredDraggedTypes.contains(.string))

        // A sorted view still takes songs dropped in from elsewhere.
        TrackTable.configureDragging(tableView, canReorder: false, acceptsDrops: true)
        #expect(tableView.registeredDraggedTypes.contains(.string))

        TrackTable.configureDragging(tableView, canReorder: false, acceptsDrops: false)
        #expect(!tableView.registeredDraggedTypes.contains(.string))
    }

    @Test("A sorted manual view appends dropped songs; an unsorted one inserts at the row")
    func dropIndex() {
        #expect(TracksView.dropIndex(row: 3, sorted: false) == 3)
        #expect(TracksView.dropIndex(row: 3, sorted: true) == nil)
    }

    // MARK: Source conventions

    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/\(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("The playlist's drop overlay covers only the empty state, never the songs table")
    func overlayOnlyOnEmptyState() throws {
        let view = try self.source("Playlists/PlaylistDetailView.swift")
        let empty = try #require(view.range(of: "EmptyState("))
        let overlay = try #require(view.range(of: "TrackDropTarget"))
        let table = try #require(view.range(of: "TracksView("))
        #expect(empty.lowerBound < overlay.lowerBound && overlay.lowerBound < table.lowerBound)
        #expect(view.components(separatedBy: "TrackDropTarget").count == 2, "one drop target only")
        #expect(view.contains("onDropTracks:"), "the table itself takes songs dropped on a playlist")
    }
}
