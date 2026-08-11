import Foundation
import Testing

// MARK: - TrackMenuSelectAllTests

/// Guards the #379 fix: the Track menu's Select All / Deselect All bindings
/// (⌘A / ⇧⌘A) intercept ahead of the responder chain, so both must route
/// through `EditMenuRouting` or they silently steal select-all from whatever
/// text field is being edited (the toolbar search box was the reported case).
@Suite("Track menu Select All routing")
struct TrackMenuSelectAllTests {
    private func commandsSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/BocanCommands+Track.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Select All forwards to the field editor before selecting tracks")
    func selectAllForwardsToTextEditor() throws {
        let source = try self.commandsSource()
        #expect(
            source.contains("EditMenuRouting.forwardSelectAllToTextEditor()"),
            "Select All must offer ⌘A to the active field editor first (#379)"
        )
    }

    @Test("Deselect All is a no-op while text is being edited")
    func deselectAllChecksTextEditor() throws {
        let source = try self.commandsSource()
        #expect(
            source.contains("EditMenuRouting.textEditorIsActive"),
            "Deselect All must not fire while a text view has focus (#379)"
        )
    }
}
