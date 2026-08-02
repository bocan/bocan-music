import Foundation
import Testing

// MARK: - ToolsMenuTests

/// Guards the Tools menu and the Library Summary window wiring (#373). Menus
/// and scenes can't be introspected without a running app, so these pin the
/// source contracts: the menu item opens the window by id, the scene exists,
/// and the new App copy routes through the app-target String Catalog rather
/// than extending the unlocalized status quo.
@Suite("Tools menu and Library Summary window")
struct ToolsMenuTests {
    private func appSource(_ fileName: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/\(fileName)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("The Tools menu offers Library Summary with the shared shortcut")
    func toolsMenuOpensSummary() throws {
        let source = try self.appSource("ToolsCommands.swift")
        #expect(source.contains("CommandMenu(\"Tools\")"), "a Tools menu must exist")
        #expect(
            source.contains("self.openWindow(id: \"library-summary\")"),
            "Library Summary must open its window by id"
        )
        #expect(
            source.contains(".keyboardShortcut(KeyBindings.librarySummary)"),
            "the shortcut must come from the shared KeyBindings table"
        )
    }

    @Test("The Library Summary window scene is registered")
    func summaryWindowSceneExists() throws {
        let source = try self.appSource("BocanApp.swift")
        #expect(
            source.contains("Window(\"Library Summary\", id: \"library-summary\")"),
            "the Library Summary window scene must be declared"
        )
        #expect(
            source.contains("LibrarySummaryWindowContent(model: self.model)"),
            "the scene must use a named content view (scene type-checker constraint)"
        )
    }

    @Test("ToolsCommands attaches inside the graph conditional, not beside it")
    func toolsCommandsLifecycle() throws {
        // A custom CommandMenu that exists before the commands tree rebuilds
        // (graph nil -> ready) is re-added next to its old self, producing a
        // duplicate Tools menu. It must share BocanCommands' lifecycle.
        let scene = try self.appSource("AppSceneContent.swift")
        let graphBranch = try #require(
            scene.range(of: "if let graph = model.graph {"),
            "AppCommands must gate its menus on the graph"
        )
        let tools = try #require(
            scene.range(of: "ToolsCommands()"),
            "ToolsCommands must be instantiated in AppCommands"
        )
        #expect(
            tools.lowerBound > graphBranch.lowerBound,
            "ToolsCommands must sit inside the graph-ready branch"
        )
        let app = try self.appSource("BocanApp.swift")
        #expect(
            !app.contains("ToolsCommands()"),
            "ToolsCommands must not also be attached unconditionally in BocanApp"
        )
    }

    @Test("The app-target String Catalog covers the new menu copy")
    func appCatalogCoversMenuCopy() throws {
        let source = try self.appSource("Localizable.xcstrings")
        #expect(source.contains("\"Tools\""), "the Tools menu title must be in the app catalog")
        #expect(
            source.contains("\"Library Summary\""),
            "the window title must be in the app catalog"
        )
        #expect(
            source.contains("\"Library Summary…\""),
            "the menu item label must be in the app catalog"
        )
    }
}
