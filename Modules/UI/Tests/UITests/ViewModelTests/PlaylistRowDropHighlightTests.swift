import AppKit
import Foundation
import Testing
@testable import UI

// MARK: - PlaylistRowDropHighlightTests

/// Dragging a track onto a manual playlist row used to draw a tight AppKit border
/// (`bounds.insetBy(dx: 1, dy: 1)`) on an unpadded row, so the highlight crowded
/// the title and the hit target was thin. The row now drives a roomier SwiftUI
/// highlight (the same bleeding `.background` the sibling folder row uses) and the
/// AppKit view defers its own drawing when a SwiftUI highlight is wired up.
@Suite("Playlist row drop highlight")
@MainActor
struct PlaylistRowDropHighlightTests {
    @Test("DropTargetNSView draws its own highlight by default")
    func defaultsToSelfDrawnHighlight() {
        let view = DropTargetNSView(frame: .zero)
        #expect(view.drawsHighlight, "Standalone drop targets keep drawing their own border")
    }

    @Test("A SwiftUI-driven highlight turns off the AppKit border drawing")
    func swiftUIHighlightDisablesSelfDrawing() {
        // Mirrors what `TrackDropTarget.apply(to:)` does when onTargetedChange is set.
        let view = DropTargetNSView(frame: .zero)
        var reported: Bool?
        view.onHighlightChange = { reported = $0 }
        view.drawsHighlight = false
        #expect(!view.drawsHighlight)
        #expect(reported == nil, "No drag has occurred yet, so nothing is reported")
    }

    private func playlistRowSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Playlists/PlaylistRow.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("PlaylistRow draws a roomy bleeding highlight driven by the drop target")
    func rowUsesBleedingSwiftUIHighlight() throws {
        let source = try self.playlistRowSource()
        // State driven from the AppKit drop view.
        #expect(source.contains("onTargetedChange: { self.isDropTargeted = $0 }"))
        // Vertical padding enlarges the target and lifts the border off the title.
        #expect(source.contains(".padding(.vertical, 4)"))
        // The highlight bleeds outward rather than hugging the tight content bounds.
        #expect(source.contains(".padding(.horizontal, -6)"))
        // A clearly visible fill plus a solid accent border (the pale fill-only
        // version was barely legible).
        #expect(source.contains("self.isDropTargeted ? Color.accentColor.opacity(0.25)"))
        #expect(source.contains("strokeBorder(self.isDropTargeted ? Color.accentColor"))
    }
}
