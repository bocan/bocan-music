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
        let source = try self.appSource("BocanCommands+Tools.swift")
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

    @Test("Exactly one Tools CommandMenu exists across the App target")
    func singleToolsMenu() throws {
        // SwiftUI does not merge same-titled CommandMenus: a second
        // CommandMenu(\"Tools\") anywhere renders a second Tools menu in the
        // menu bar (the regression behind the duplicate-menu report on #373).
        let appDir = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App")
        let files = try FileManager.default.contentsOfDirectory(
            at: appDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        var declarations = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            declarations += source.components(separatedBy: "CommandMenu(\"Tools\")").count - 1
        }
        #expect(declarations == 1, "found \(declarations) CommandMenu(\"Tools\") declarations; must be exactly 1")
    }

    @Test("The Tools menu starts the provenance batch through the view model")
    func toolsMenuStartsProvenance() throws {
        let source = try self.appSource("BocanCommands+Tools.swift")
        #expect(
            source.contains("Button(\"Analyse Provenance\\u{2026}\")"),
            "the Analyse Provenance item must exist"
        )
        #expect(
            source.contains("self.vm.startProvenanceAnalysis()"),
            "the item must start the batch via the view model so cancel and re-run guards apply"
        )
    }

    @Test("The Tools menu imports Last.fm history through the view model")
    func toolsMenuImportsListens() throws {
        let source = try self.appSource("BocanCommands+Tools.swift")
        #expect(
            source.contains("Button(\"Import Last.fm History\\u{2026}\")"),
            "the Import Last.fm History item must exist"
        )
        #expect(
            source.contains("self.vm.importListeningHistoryByPicker()"),
            "the item must go through the view model's picker flow"
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
        #expect(
            source.contains("\"Analyse Provenance…\""),
            "the provenance menu item label must be in the app catalog"
        )
    }
}
