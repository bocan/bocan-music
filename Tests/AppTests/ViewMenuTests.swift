import Foundation
import Testing

// MARK: - ViewMenuTests

/// Guards the menu-bar structure for the View menu and standard Edit/Window
/// affordances (issues #303 and #304).
///
/// The menus live in a `Commands` builder that can't be introspected without a
/// running menu bar, so this pins the source contract: the presentation toggles
/// live in the (single, system) View menu alongside Show/Hide Sidebar, they are
/// no longer appended to the Window menu, and the commands never strip the
/// standard Cut/Copy/Paste/Undo groups.
@Suite("View / Edit menus")
struct ViewMenuTests {
    private func commandsSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/BocanCommands.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: View menu (#303 / #304)

    @Test("SidebarCommands restores Show/Hide Sidebar in the View menu (#304)")
    func sidebarCommandsPresent() throws {
        let source = try self.commandsSource()
        #expect(source.contains("SidebarCommands()"), "Show/Hide Sidebar must be provided via SidebarCommands()")
    }

    @Test("Presentation toggles live in the system View menu via the sidebar group (#303)")
    func togglesInSystemViewMenu() throws {
        let source = try self.commandsSource()
        #expect(
            source.contains("CommandGroup(after: .sidebar)"),
            "View toggles must be added to the system View menu (after .sidebar), not a duplicate custom menu"
        )
        // No custom "View" CommandMenu — that would risk a second View menu next
        // to the system one that SidebarCommands populates.
        #expect(!source.contains("CommandMenu(\"View\")"), "Must not create a custom View menu alongside the system one")
    }

    @Test("View toggles moved out of the Window menu (#303)")
    func togglesNoLongerInWindowMenu() throws {
        let source = try self.commandsSource()
        #expect(
            !source.contains("CommandGroup(after: .windowArrangement)"),
            "The view toggles must no longer be appended to the Window menu"
        )
    }

    @Test("The six view toggles live in the View (sidebar) group (#303)")
    func togglesAreInsideViewGroup() throws {
        let source = try self.commandsSource()
        let viewStart = try #require(source.range(of: "CommandGroup(after: .sidebar)"))
        // The View group is declared before the Playback menu, so its body is the
        // span between the two declarations.
        let playbackStart = try #require(source.range(of: "CommandMenu(\"Playback\")"))
        #expect(viewStart.lowerBound < playbackStart.lowerBound, "View group must precede the app-specific menus")
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

    // MARK: Standard Edit / Window groups (#304)

    @Test("Standard Cut/Copy/Paste and Undo/Redo groups are not stripped (#304)")
    func standardEditGroupsPreserved() throws {
        let source = try self.commandsSource()
        // Cut/Copy/Paste live in .pasteboard, Undo/Redo in .undoRedo. Replacing
        // either would remove the standard Edit items; we must not.
        #expect(!source.contains("replacing: .pasteboard"), "Must not replace the Cut/Copy/Paste group")
        #expect(!source.contains("replacing: .undoRedo"), "Must not replace the Undo/Redo group")
    }

    @Test("Window menu is not wholesale-replaced, so Zoom/Minimize remain (#304)")
    func windowGroupNotReplaced() throws {
        let source = try self.commandsSource()
        #expect(!source.contains("replacing: .windowArrangement"), "Must not replace the standard Window items")
        #expect(!source.contains("replacing: .windowSize"), "Must not replace the standard Window items")
    }
}
