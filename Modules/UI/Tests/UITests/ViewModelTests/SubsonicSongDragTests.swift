import AppKit
import Foundation
import Playback
import Testing
@testable import UI

// MARK: - SubsonicSongDragTests

/// Covers dragging streamed Subsonic songs into the Up Next queue (#332): the
/// pasteboard payload round-trips, the queue item is built correctly, and the
/// drag source / drop target are wired.
@Suite("Subsonic song drag")
@MainActor
struct SubsonicSongDragTests {
    private func payload(songID: String = "song-1", title: String = "Faded") -> SubsonicSongDragPayload {
        SubsonicSongDragPayload(
            serverID: UUID(),
            songID: songID,
            title: title,
            artist: "Alan Walker",
            album: "Different World",
            genre: "Electronic",
            durationSeconds: 212
        )
    }

    @Test("Payload encodes to a pasteboard item and decodes back (#332)")
    func pasteboardRoundTrip() throws {
        let a = self.payload(songID: "a", title: "A")
        let b = self.payload(songID: "b", title: "B")
        let item = try #require(SubsonicSongDrag.pasteboardItem(for: [a, b]))
        let decoded = SubsonicSongDrag.payloads(from: [item])
        #expect(decoded == [a, b])
    }

    @Test("An empty payload list produces no pasteboard item (#332)")
    func emptyProducesNil() {
        #expect(SubsonicSongDrag.pasteboardItem(for: []) == nil)
    }

    @Test("Decoding ignores pasteboard items without the Subsonic type (#332)")
    func ignoresForeignItems() {
        let foreign = NSPasteboardItem()
        foreign.setString("42", forType: .string)
        #expect(SubsonicSongDrag.payloads(from: [foreign]).isEmpty)
    }

    @Test("makeSubsonic(from payload:) builds a .subsonic queue item (#332)")
    func makesSubsonicQueueItem() {
        let p = self.payload(songID: "song-42", title: "Faded")
        let item = QueueItem.makeSubsonic(from: p)

        #expect(item.trackID == -1)
        #expect(item.title == "Faded")
        #expect(item.artistName == "Alan Walker")
        #expect(item.albumName == "Different World")
        #expect(item.genre == "Electronic")
        #expect(item.duration == 212)
        guard case let .subsonic(serverID, songID) = item.playableSource else {
            Issue.record("Expected a .subsonic playable source, got \(item.playableSource)")
            return
        }
        #expect(serverID == p.serverID)
        #expect(songID == "song-42")
    }
}

// MARK: - Source-convention wiring

@Suite("Subsonic song drag wiring")
struct SubsonicSongDragWiringTests {
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

    @Test("SubsonicSongTable is a drag source for streamed songs (#332)")
    func tableIsDragSource() throws {
        let src = try self.source("Browse/Subsonic/SubsonicSongTable.swift")
        #expect(src.contains("pasteboardWriterForRow"), "the table must write a drag payload per row")
        #expect(src.contains("setDraggingSourceOperationMask(.copy, forLocal: true)"), "rows must be draggable out")
    }

    @Test("The Up Next queue accepts the Subsonic drop (#332)")
    func queueAcceptsDrop() throws {
        let src = try self.source("Browse/QueueView.swift")
        #expect(src.contains("SubsonicSongDropTarget"), "Up Next must overlay the Subsonic drop target")
        #expect(src.contains("addSubsonicSongsToQueue"), "a drop must enqueue the songs")
    }
}
