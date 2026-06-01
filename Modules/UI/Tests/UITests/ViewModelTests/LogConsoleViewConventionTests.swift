import Foundation
import Testing
@testable import UI

// MARK: - LogConsoleViewConventionTests

/// Source-convention checks for `LogConsoleView` and `LogConsoleRow` (#phase-20).
///
/// These tests read the Swift source files directly and assert that structural
/// invariants — lifecycle hooks, accessibility, tail-scroll wiring — are present.
/// They run in both the SPM (`make test-ui`) and the Xcode bundle test targets.
@Suite("LogConsoleView Source Conventions")
struct LogConsoleViewConventionTests {
    // MARK: - Helpers

    private var uiSourcesURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    private func sourceContents(at relativePath: String) throws -> String {
        let url = self.uiSourcesURL.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - LogConsoleView

    @Test("LogConsoleView has .task lifecycle to start the VM")
    func viewHasTaskLifecycle() throws {
        let source = try self.sourceContents(at: "Console/LogConsoleView.swift")
        #expect(
            source.contains(".task { self.vm.start() }"),
            "LogConsoleView must start the VM via .task { vm.start() }"
        )
    }

    @Test("LogConsoleView has .onDisappear lifecycle to stop the VM")
    func viewHasOnDisappearLifecycle() throws {
        let source = try self.sourceContents(at: "Console/LogConsoleView.swift")
        #expect(
            source.contains(".onDisappear { self.vm.stop() }"),
            "LogConsoleView must stop the VM via .onDisappear { vm.stop() }"
        )
    }

    @Test("LogConsoleView uses ScrollViewReader for tail-scroll")
    func viewHasScrollViewReader() throws {
        let source = try self.sourceContents(at: "Console/LogConsoleView.swift")
        #expect(
            source.contains("ScrollViewReader"),
            "LogConsoleView must wrap the list in a ScrollViewReader for tail-scroll"
        )
    }

    @Test("LogConsoleView calls scrollTo when tailing")
    func viewHasScrollTo() throws {
        let source = try self.sourceContents(at: "Console/LogConsoleView.swift")
        #expect(
            source.contains("scrollTo("),
            "LogConsoleView must call proxy.scrollTo(...) to implement tail-scroll"
        )
    }

    @Test("LogConsoleView has jump-to-latest affordance")
    func viewHasJumpToLatest() throws {
        let source = try self.sourceContents(at: "Console/LogConsoleView.swift")
        #expect(
            source.contains("jumpToLatestButton") || source.contains("Jump to Latest"),
            "LogConsoleView must provide a jump-to-latest button for re-engaging tail mode"
        )
    }

    @Test("LogConsoleView shows capacity banner when isAtCapacity")
    func viewHasCapacityBanner() throws {
        let source = try self.sourceContents(at: "Console/LogConsoleView.swift")
        #expect(
            source.contains("isAtCapacity"),
            "LogConsoleView must show a capacity banner when vm.isAtCapacity is true"
        )
    }

    // MARK: - LogConsoleRow

    @Test("LogConsoleRow enables text selection")
    func rowHasTextSelection() throws {
        let source = try self.sourceContents(at: "Console/LogConsoleRow.swift")
        #expect(
            source.contains("textSelection(.enabled)"),
            "LogConsoleRow must enable text selection on the message text"
        )
    }

    @Test("LogConsoleRow always renders level as text (never color alone)")
    func rowRendersLevelAsText() throws {
        let source = try self.sourceContents(at: "Console/LogConsoleRow.swift")
        #expect(
            source.contains("entry.level.label"),
            "LogConsoleRow must render the level label as text (not color alone)"
        )
    }

    @Test("LogConsoleRow has accessibilityLabel")
    func rowHasAccessibilityLabel() throws {
        let source = try self.sourceContents(at: "Console/LogConsoleRow.swift")
        #expect(
            source.contains("accessibilityLabel("),
            "LogConsoleRow must declare an accessibilityLabel for VoiceOver"
        )
    }

    @Test("LogConsoleRow respects differentiateWithoutColor")
    func rowRespectsDifferentiateWithoutColor() throws {
        let source = try self.sourceContents(at: "Console/LogConsoleRow.swift")
        #expect(
            source.contains("differentiateWithoutColor"),
            "LogConsoleRow must read the differentiateWithoutColor environment key"
        )
    }

    // MARK: - Step 9: Polish + Export

    @Test("LogConsoleView provides a Clear Buffer action")
    func viewHasClearBuffer() throws {
        let source = try self.sourceContents(at: "Console/LogConsoleView.swift")
        #expect(
            source.contains("clearBuffer"),
            "LogConsoleView must expose a Clear Buffer action to empty the ring buffer"
        )
    }

    @Test("LogConsoleView overflow menu label contains 'Clear Buffer'")
    func viewHasClearBufferLabel() throws {
        let source = try self.sourceContents(at: "Console/LogConsoleView.swift")
        #expect(
            source.contains("\"Clear Buffer\""),
            "LogConsoleView must have a 'Clear Buffer' label in the clear menu"
        )
    }

    @Test("LogConsoleView search field has an accessibility label")
    func searchFieldHasAccessibilityLabel() throws {
        let source = try self.sourceContents(at: "Console/LogConsoleView.swift")
        #expect(
            source.contains("Search log entries"),
            "The search text field must have an .accessibilityLabel for VoiceOver"
        )
    }

    @Test("LogConsoleView capacity banner image is hidden from accessibility")
    func capacityBannerImageIsAccessibilityHidden() throws {
        let source = try self.sourceContents(at: "Console/LogConsoleView.swift")
        #expect(
            source.contains("accessibilityHidden(true)"),
            "The capacity banner icon must be hidden from VoiceOver (.accessibilityHidden(true))"
        )
    }

    @Test("LogConsoleView line count label has an accessibility label")
    func lineCountHasAccessibilityLabel() throws {
        let source = try self.sourceContents(at: "Console/LogConsoleView.swift")
        #expect(
            source.contains("log entries visible"),
            "The line count label must have an .accessibilityLabel describing the visible entry count"
        )
    }
}
