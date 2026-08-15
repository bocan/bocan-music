import Foundation
import Testing

// MARK: - WindowTabbingTests

/// Guards the app-wide window tabbing opt-out.
///
/// Every main window renders the same shared `LibraryViewModel`, so native
/// macOS window tabs are mirrors, not browse contexts: navigating in one
/// "tab" changes all of them. Until tabs hold per-window navigation state,
/// the app disables tabbing outright. The delegate callback cannot run
/// host-less, so this pins the source contract instead.
@Suite("Window tabbing")
struct WindowTabbingTests {
    private func appSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/BocanApp.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Automatic window tabbing is disabled before any window exists")
    func tabbingDisabledAtLaunch() throws {
        let source = try self.appSource()
        #expect(source.contains("NSWindow.allowsAutomaticWindowTabbing = false"))
        // willFinishLaunching, not didFinish: state restoration can recreate
        // windows before didFinishLaunching, and those must not tab either.
        let willFinish = source.range(of: "func applicationWillFinishLaunching")
        let tabbing = source.range(of: "NSWindow.allowsAutomaticWindowTabbing = false")
        let didFinish = source.range(of: "func applicationDidFinishLaunching")
        let willFinishIndex = try #require(willFinish?.lowerBound)
        let tabbingIndex = try #require(tabbing?.lowerBound)
        let didFinishIndex = try #require(didFinish?.lowerBound)
        #expect(willFinishIndex < tabbingIndex && tabbingIndex < didFinishIndex)
    }
}

// MARK: - WindowMenuHygieneTests

/// Guards against SwiftUI's auto-injected Window-menu opener items.
///
/// Every secondary `Window` scene must call `.commandsRemoved()`, or SwiftUI
/// adds an opener for it to the Window menu, duplicating the scene's real
/// opener (app menu, Help, Tools, or an in-window button). Debug Audio is the
/// deliberate exception: the auto item is its only opener, and the window is
/// compiled out of Release.
@Suite("Window menu hygiene")
struct WindowMenuHygieneTests {
    /// Secondary window scene ids whose auto-injected item must be removed.
    private static let removedIDs = [
        "about", "bocan-help", "notices", "track-info",
        "visualizer-fullscreen", "dsp", "library-summary", "mini", "log-console",
    ]

    private func appSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/BocanApp.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The scene declaration's trailing-modifier region: from its `id:` up to
    /// the next scene declaration (or end of file for the last one).
    private func sceneChunk(id: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: "id: \"\(id)\""), "scene id \(id) not found").upperBound
        let rest = source[start...]
        let end = rest.range(of: "Window(")?.lowerBound
            ?? rest.range(of: "MenuBarExtra(")?.lowerBound
            ?? rest.endIndex
        return rest[..<end]
    }

    @Test("Every secondary window scene removes its auto-injected Window-menu item")
    func secondaryScenesRemoveAutoItems() throws {
        let source = try self.appSource()
        for id in Self.removedIDs {
            let chunk = try self.sceneChunk(id: id, in: source)
            #expect(chunk.contains(".commandsRemoved()"), "scene \(id) leaks a Window-menu item")
        }
    }

    @Test("Debug Audio keeps its auto item; it is the window's only opener")
    func debugAudioKeepsAutoItem() throws {
        let source = try self.appSource()
        let chunk = try self.sceneChunk(id: "debug-audio", in: source)
        #expect(!chunk.contains(".commandsRemoved()"))
    }

    @Test("The DSP scene carries no scene-level keyboard shortcut")
    func dspSceneHasNoShortcut() throws {
        // The scene modifier only decorated the removed auto item; the Tools
        // menu item is the single owner of KeyBindings.showEQPanel.
        let source = try self.appSource()
        let chunk = try self.sceneChunk(id: "dsp", in: source)
        #expect(!chunk.contains(".keyboardShortcut"))
    }
}
