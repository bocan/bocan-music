import Foundation
import Testing
@testable import UI

// MARK: - SidebarHeaderAccessibilityConventionTests

/// #596: a sidebar `List` merges every control in a section header into one
/// accessibility element, so the Playlists "+" answered to VoiceOver as
/// "Collapse Playlists" and the collapse button did not exist for it. Every
/// header is now one deliberate element (`SidebarHeaderAccessibility`), with
/// its "+" offered as named actions.
@Suite("Sidebar header accessibility")
struct SidebarHeaderAccessibilityConventionTests {
    private var uiSourcesURL: URL {
        // #filePath: .../Modules/UI/Tests/UITests/SidebarHeaderAccessibilityConventionTests.swift
        URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: self.uiSourcesURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("The modifier makes one element with the section's name, state and collapse action")
    func modifierShape() throws {
        let code = try self.source("AppRoot/SidebarHeaderAccessibility.swift")
        #expect(code.contains(".accessibilityElement(children: .ignore)"))
        #expect(code.contains(".accessibilityLabel(self.title)"))
        #expect(code.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(code.contains("L10n.string(\"Collapse \\(self.title)\")"))
    }

    @Test("Every sidebar header applies the modifier")
    func everyHeaderApplies() throws {
        let sources = try self.source("AppRoot/SubsonicSidebarSection.swift")
        // SidebarSectionHeader (Local Library, Recents, Queue) and the Sources header.
        #expect(sources.components(separatedBy: ".sidebarHeaderAccessibility(").count - 1 == 2)
        #expect(try self.source("Playlists/PlaylistSidebarSection.swift").contains(".sidebarHeaderAccessibility("))
    }

    @Test("Each header offers its + as named actions")
    func plusIsANamedAction() throws {
        let sources = try self.source("AppRoot/SubsonicSidebarSection.swift")
        #expect(sources.contains(".accessibilityAction(named: action.title)"))
        #expect(sources.contains(".accessibilityAction(named: L10n.string(\"Add Source\"))"))
        let playlists = try self.source("Playlists/PlaylistSidebarSection.swift")
        for name in ["New Playlist", "New Smart Playlist", "New Folder"] {
            #expect(playlists.contains(".accessibilityAction(named: L10n.string(\"\(name)\"))"), "missing \(name)")
        }
    }
}
