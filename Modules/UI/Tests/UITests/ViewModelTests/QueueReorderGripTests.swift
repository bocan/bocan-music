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
}
