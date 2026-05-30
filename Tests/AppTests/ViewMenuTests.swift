import Foundation
import Testing

// MARK: - ViewMenuTests

/// Guards that the presentation toggles live under a dedicated `View` menu rather
/// than being buried in the Window menu (issue #303).
///
/// The menu lives in a `Commands` builder that can't be introspected without a
/// running menu bar, so this pins the source contract: a `CommandMenu("View")`
/// exists, contains the view toggles, sits ahead of the app-specific menus, and
/// the old Window-menu (`.windowArrangement`) group is gone.
@Suite("View menu")
struct ViewMenuTests {
    private func commandsSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/BocanCommands.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("A dedicated View menu exists (#303)")
    func viewMenuExists() throws {
        let source = try self.commandsSource()
        #expect(source.contains("CommandMenu(\"View\")"), "Presentation toggles must live under a CommandMenu(\"View\")")
    }

    @Test("View toggles moved out of the Window menu (#303)")
    func togglesNoLongerInWindowMenu() throws {
        let source = try self.commandsSource()
        // The old block appended these to the Window menu via .windowArrangement.
        #expect(
            !source.contains("CommandGroup(after: .windowArrangement)"),
            "The view toggles must no longer be appended to the Window menu"
        )
    }

    @Test("The six view toggles live inside the View menu (#303)")
    func togglesAreInsideViewMenu() throws {
        let source = try self.commandsSource()
        let viewStart = try #require(source.range(of: "CommandMenu(\"View\")"))
        // The View menu is declared before the Playback menu, so its body is the
        // span between the two declarations.
        let playbackStart = try #require(source.range(of: "CommandMenu(\"Playback\")"))
        #expect(viewStart.lowerBound < playbackStart.lowerBound, "View menu must be declared before Playback so it sits right after Edit")
        let viewBody = String(source[viewStart.upperBound ..< playbackStart.lowerBound])
        for label in [
            "Show Lyrics",
            "Show Visualizer",
            "Open Fullscreen Visualizer",
            "Toggle Miniplayer",
            "Show Recent Scrobbles",
            "Equaliser & DSP",
        ] {
            #expect(viewBody.contains(label), "View menu is missing: \(label)")
        }
    }

    @Test("View menu precedes the other app-specific menus (#303)")
    func viewMenuIsFirstCustomMenu() throws {
        let source = try self.commandsSource()
        let view = try #require(source.range(of: "CommandMenu(\"View\")"))
        for later in ["CommandMenu(\"Playback\")", "CommandMenu(\"Track\")", "CommandMenu(\"Tools\")"] {
            let other = try #require(source.range(of: later))
            #expect(view.lowerBound < other.lowerBound, "View must be declared before \(later)")
        }
    }
}
