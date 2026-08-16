import Foundation
import Testing
@testable import UI

// MARK: - SidebarRowIdentifierTests

/// Regression (ADR-081 invocation pass): the tag-selected sidebar
/// destination rows were absent from the accessibility tree entirely, so
/// VoiceOver could not reach them and the E2E menu crawl could not click
/// them. The `sidebarRow` builder must attach a stable `A11y` identifier.
/// Source-convention test: the view internals cannot be exercised
/// host-less.
@Suite("Sidebar row identifiers")
struct SidebarRowIdentifierTests {
    private func sidebarSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/AppRoot/Sidebar.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the sidebar row builder attaches an accessibility identifier")
    func rowBuilderAttachesIdentifier() throws {
        let source = try self.sidebarSource()
        #expect(
            source.contains(".accessibilityIdentifier(Self.rowIdentifier(for: dest))"),
            "sidebarRow must attach a stable A11y identifier so the rows are reachable"
        )
    }

    @Test("every fixed destination maps to its A11y.Sidebar identifier")
    func rowIdentifierCoversDestinations() throws {
        let source = try self.sidebarSource()
        for identifier in [
            "A11y.Sidebar.songs", "A11y.Sidebar.albums", "A11y.Sidebar.artists",
            "A11y.Sidebar.genres", "A11y.Sidebar.composers", "A11y.Sidebar.recentlyAdded",
            "A11y.Sidebar.recentlyPlayed", "A11y.Sidebar.mostPlayed",
            "A11y.Sidebar.upNext", "A11y.Sidebar.radio",
        ] {
            #expect(source.contains(identifier), "rowIdentifier must map to \(identifier)")
        }
    }
}
