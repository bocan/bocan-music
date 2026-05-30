import Foundation
import Testing

// MARK: - SettingsMenuTests

/// Guards that a menu item can deep-link to a specific Settings page via the
/// shared router (#305) — the File menu's "Music Sources…" opens Settings ▸
/// Sources so server setup is discoverable from the menu bar, not only the
/// sidebar. The wiring lives in a `Commands` builder that can't be introspected
/// without a running menu bar, so this pins the source contract.
@Suite("Settings menu deep-link")
struct SettingsMenuTests {
    private func commandsSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/BocanCommands.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("A menu item deep-links to Settings ▸ Sources via the router (#305)")
    func musicSourcesMenuItemDeepLinks() throws {
        let source = try self.commandsSource()
        #expect(source.contains("Music Sources"), "A 'Music Sources…' menu item should exist")
        #expect(
            source.contains("self.settingsRouter.open(.sources)"),
            "The menu item must deep-link via the shared SettingsRouter"
        )
        #expect(source.contains("self.openSettings()"), "The menu item must bring the Settings window forward")
    }
}
