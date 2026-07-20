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

    // MARK: "View as" collection mode items (#363)

    @Test("The View menu mirrors the collection List / Grid toggle, radio-style and gated")
    func collectionViewModeItems() throws {
        let source = try self.commandsSource()
        // A radio-style inline picker with the two labelled items.
        #expect(source.contains("Picker(\"View as\""), "the View menu must offer a \"View as\" picker")
        #expect(
            source.contains("as List") && source.contains("as Album Grid"),
            "the picker must offer 'as List' and 'as Album Grid'"
        )
        #expect(source.contains(".pickerStyle(.inline)"), "radio checkmarks come from an inline picker style")
        // Disabled unless the visible destination is a collection listing.
        #expect(
            source.contains(".disabled(!self.isCollectionListing)"),
            "the items must be disabled off the collection listings"
        )
        // They live in the View (sidebar) group, before the app-specific menus.
        let viewStart = try #require(source.range(of: "CommandGroup(after: .sidebar)"))
        let playbackStart = try #require(source.range(of: "CommandMenu(\"Playback\")"))
        let viewBody = String(source[viewStart.upperBound ..< playbackStart.lowerBound])
        #expect(viewBody.contains("Picker(\"View as\""), "the 'View as' picker must sit in the View menu group")
    }

    @Test("The View-menu mode picker routes to the active section's viewMode key (#363)")
    func collectionViewModeRouting() throws {
        // The three keys are declared (and written) in BocanCommands.swift.
        let commands = try self.commandsSource()
        for key in ["artists.viewMode", "genres.viewMode", "composers.viewMode"] {
            #expect(
                commands.contains("@CollectionViewModeStorage(\"\(key)\")"),
                "must declare @CollectionViewModeStorage for \(key)"
            )
        }
        // The get/set routing by destination lives in the helper extension.
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/BocanCommands+CollectionViewMenu.swift")
        let helpers = try String(contentsOf: url, encoding: .utf8)
        #expect(helpers.contains("self.vm.selectedDestination"), "routing must read the active destination")
        #expect(helpers.contains("self.genresViewMode = newValue"), "must write genres to genresViewMode")
        #expect(helpers.contains("self.composersViewMode = newValue"), "must write composers to composersViewMode")
        #expect(helpers.contains("self.artistsViewMode = newValue"), "must write artists to artistsViewMode")
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
