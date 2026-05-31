import Foundation
import Testing
@testable import UI

// MARK: - SidebarAddFolderTests

/// Guards the persistent "Add Folder" affordance in the Local Library sidebar
/// header (#308). Adding music must be reachable from any destination, not only
/// the empty-state button, the File menu, and Settings. The affordance is a
/// SwiftUI view detail (a header accessory), so this pins the source contract.
@Suite("Sidebar Add Folder")
struct SidebarAddFolderTests {
    private var uiSourcesURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: self.uiSourcesURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("Local Library header wires a persistent Add Folder action (#308)")
    func localLibraryHeaderHasAddFolder() throws {
        let sidebar = try self.source("AppRoot/Sidebar.swift")
        #expect(
            sidebar.contains("A11y.Sidebar.addFolderButton"),
            "The Local Library header must expose the Add Folder affordance"
        )
        #expect(
            sidebar.contains("addFolderByPicker"),
            "The Add Folder affordance must call addFolderByPicker"
        )
    }

    @Test("SidebarSectionHeader renders a trailing + button when given an action (#308)")
    func headerRendersPlusAffordance() throws {
        let header = try self.source("AppRoot/SubsonicSidebarSection.swift")
        // The shared header type gained an optional Action that draws a trailing "+".
        #expect(header.contains("struct Action"), "SidebarSectionHeader must support an optional Action")
        #expect(header.contains("Image(systemName: \"plus\")"), "An action header must render a + button")
    }
}
