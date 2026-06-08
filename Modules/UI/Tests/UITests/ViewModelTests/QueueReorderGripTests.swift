import Foundation
import Testing
@testable import UI

// MARK: - QueueReorderGripTests

/// Guards the hover-revealed reorder grip on Up Next rows (#313). The grip is a
/// private SwiftUI view detail (hover state + opacity), so this pins the source
/// contract rather than rendering a live row.
@Suite("Queue reorder grip")
struct QueueReorderGripTests {
    private func queueSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Browse/QueueView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("QueueRow shows a line.3.horizontal grip revealed on hover (#313)")
    func rowHasHoverGrip() throws {
        let source = try self.queueSource()
        #expect(
            source.contains("line.3.horizontal"),
            "QueueRow must render a line.3.horizontal reorder grip"
        )
        #expect(
            source.contains(".onHover") && source.contains("self.isHovered"),
            "The grip must be revealed on hover so the reorder affordance is discoverable"
        )
    }

    @Test("Up Next pins the now-playing track at the top of the list")
    func upNextPinsNowPlayingAtTop() throws {
        let source = try self.queueSource()
        // The list iterates the `upcoming` slice, not the full enumerated queue,
        // so the playhead and everything after it is what gets rendered.
        #expect(
            source.contains("ForEach(self.upcoming)"),
            "Up Next must render the `upcoming` slice so the current track leads the list"
        )
        // `upcoming` is a suffix anchored at the current index: the now-playing
        // track is the first visible row, tracks behind the playhead are hidden.
        #expect(
            source.contains("start ..< self.items.count"),
            "`upcoming` must slice from the playhead to the end of the queue"
        )
        // The current row is visually distinguished (the 'highlighted/selected' ask).
        #expect(
            source.contains("listRowBackground") && source.contains("entry.isCurrent"),
            "The now-playing row must be visually highlighted"
        )
    }
}
