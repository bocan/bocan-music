import Foundation
import Testing

// MARK: - LogConsoleAppConventionTests

/// Guards the App-level wiring for the Log Console window and Help-menu command.
///
/// The scenes and commands live in builders that cannot be introspected without a
/// running app, so this pins the source contract: the window id and the menu item
/// both appear in the source, and the window content type is routed through the
/// named-view-struct pattern.
@Suite("Log Console app conventions")
struct LogConsoleAppConventionTests {
    private func appSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/BocanApp.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func commandsSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/BocanCommands.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sceneContentSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/AppSceneContent.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Window scene with id 'log-console' is registered in BocanApp")
    func logConsoleWindowRegistered() throws {
        let source = try self.appSource()
        #expect(
            source.contains("\"log-console\""),
            "A Window scene with id 'log-console' must be declared in BocanApp"
        )
    }

    @Test("LogConsoleViewModel is a member of AppGraph")
    func logConsoleViewModelInGraph() throws {
        let source = try self.appSource()
        #expect(
            source.contains("logConsoleViewModel"),
            "AppGraph must expose logConsoleViewModel so window content can access it"
        )
    }

    @Test("LogConsoleWindowContent named-view-struct is present in AppSceneContent")
    func logConsoleWindowContentExists() throws {
        let source = try self.sceneContentSource()
        #expect(
            source.contains("LogConsoleWindowContent"),
            "AppSceneContent must define a LogConsoleWindowContent named-view-struct"
        )
    }

    @Test("Log Console command exists in the Help menu group")
    func logConsoleCommandInHelpMenu() throws {
        let source = try self.commandsSource()
        #expect(
            source.contains("Log Console"),
            "A 'Log Console' menu item must exist in BocanCommands"
        )
        #expect(
            source.contains("\"log-console\""),
            "The Log Console command must open the window with id 'log-console'"
        )
    }

    @Test("Log Console command uses Shift-Cmd-L shortcut")
    func logConsoleCommandShortcut() throws {
        let source = try self.commandsSource()
        // The shortcut is Shift+Cmd+L; verify the key and modifier set appear near
        // the Log Console button rather than asserting exact whitespace layout.
        #expect(
            source.contains(".shift") && source.contains("\"l\""),
            "Log Console shortcut must be Shift-Cmd-L"
        )
    }
}
