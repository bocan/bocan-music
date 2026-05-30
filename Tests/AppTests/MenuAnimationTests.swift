import Foundation
import Testing

// MARK: - MenuAnimationTests

/// Guards that the lyrics / visualizer menu toggles animate the pane the same
/// way the toolbar buttons do, instead of flipping visibility bare (issue #312).
///
/// The behaviour lives in a `Commands` action closure that can't be invoked
/// without a running menu, so this pins the source contract: both toggles route
/// through the reduce-motion-aware `toggleAnimated(_:)` helper rather than a bare
/// `.toggle()`.
@Suite("Menu toggle animation")
struct MenuAnimationTests {
    private func commandsSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/BocanCommands.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Lyrics and visualizer menu toggles use the animated helper (#312)")
    func paneTogglesUseAnimatedHelper() throws {
        let source = try self.commandsSource()
        #expect(
            source.contains("self.toggleAnimated(self.$lyricsPaneVisible)"),
            "The Show/Hide Lyrics menu item must animate via toggleAnimated, matching the toolbar"
        )
        #expect(
            source.contains("self.toggleAnimated(self.$visualizerPaneVisible)"),
            "The Show/Hide Visualizer menu item must animate via toggleAnimated"
        )
    }

    @Test("Animated toggle helper respects Reduce Motion (#312)")
    func animatedHelperRespectsReduceMotion() throws {
        let source = try self.commandsSource()
        #expect(
            source.contains("accessibilityReduceMotion") && source.contains("appReduceMotion"),
            "toggleAnimated must suppress the animation under system or in-app Reduce Motion"
        )
    }
}
