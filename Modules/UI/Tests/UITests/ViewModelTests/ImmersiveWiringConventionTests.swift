import Foundation
import Testing
@testable import UI

// MARK: - ImmersiveWiringConventionTests

/// ADR-089 slice 4: Immersive Mode is its own hidden-title-bar window. One
/// preference key mirrors whether it is open, the toolbar and the View menu
/// open or dismiss it, Esc closes it from inside, the root reopens it after
/// bootstrap, and the E2E seeder clears the key. Source conventions, because
/// scenes, the menu bar and window presentation cannot be exercised
/// host-less.
@Suite("Immersive Mode wiring conventions")
struct ImmersiveWiringConventionTests {
    private var moduleRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
    }

    private var repoRoot: URL {
        self.moduleRoot
            .deletingLastPathComponent() // Modules/
            .deletingLastPathComponent() // repo
    }

    private func source(_ relativePath: String, from root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("one preference key and one window identifier")
    func identifiers() {
        #expect(ImmersiveView.preferenceKey == "ui.immersive.visible")
        #expect(ImmersiveWindowView.windowID == "immersive")
    }

    @Test("the scene is a hidden-title-bar secondary window with restoration disabled")
    func sceneShape() throws {
        let app = try self.source("App/BocanApp.swift", from: self.repoRoot)
        let scene = try #require(app.range(of: "Window(\"Immersive Mode\", id: \"immersive\")"))
        let tail = String(app[scene.upperBound...].prefix(600))
        #expect(tail.contains("ImmersiveWindowContent(model: self.model)"))
        #expect(tail.contains(".windowStyle(.hiddenTitleBar)"))
        #expect(tail.contains(".restorationBehavior(.disabled)"))
        #expect(tail.contains(".commandsRemoved()"))
        let content = try self.source("App/AppSceneContent.swift", from: self.repoRoot)
        #expect(content.contains("ImmersiveWindowView("))
    }

    @Test("the window content mirrors the open flag and closes on Esc")
    func windowContent() throws {
        let window = try self.source("Sources/UI/Immersive/ImmersiveWindowView.swift", from: self.moduleRoot)
        #expect(window.contains(".onAppear { self.isOpen = true }"))
        #expect(window.contains(".onDisappear { self.isOpen = false }"))
        #expect(window.contains(".onKeyPress(.escape)"))
        #expect(window.contains("self.dismissWindow(id: Self.windowID)"))
        #expect(window.contains(".ignoresSafeArea()"))
    }

    @Test("the root reopens the window after bootstrap and no longer hosts an overlay")
    func rootRestoresAndHostsNoOverlay() throws {
        let root = try self.source("Sources/UI/AppRoot/RootView.swift", from: self.moduleRoot)
        #expect(root.contains("@AppStorage(ImmersiveView.preferenceKey) private var immersiveOpen = false"))
        let restore = try #require(root.range(of: "self.windowMode.restoreIfNeeded()"))
        // The toolbar closure opens the window too; the reopen must follow
        // the mini player restore inside the bootstrap task.
        let afterRestore = restore.upperBound ..< root.endIndex
        let reopen = root.range(of: "self.openWindow(id: ImmersiveWindowView.windowID)", range: afterRestore)
        #expect(reopen != nil)
        #expect(!root.contains("ImmersiveOverlay"))
        #expect(!root.contains("ImmersiveView("))
        let monitor = try self.source("Sources/UI/AppRoot/NavigationInputMonitor.swift", from: self.moduleRoot)
        #expect(!monitor.contains("Immersive"))
    }

    @Test("the toolbar toggles the window beside the other view toggles, with an identifier and localized help")
    func toolbarButton() throws {
        let root = try self.source("Sources/UI/AppRoot/RootView.swift", from: self.moduleRoot)
        #expect(root.contains("self.dismissWindow(id: ImmersiveWindowView.windowID)"))
        let toolbar = try self.source("Sources/UI/AppRoot/MainToolbarItems.swift", from: self.moduleRoot)
        #expect(toolbar.contains(".accessibilityIdentifier(A11y.Toolbar.immersiveToggle)"))
        #expect(toolbar.contains("L10n.string(\"Toggle Immersive Mode (⇧⌘I)\")"))
        #expect(toolbar.contains("self.toggleImmersive()"))
        // The strip has no slack at the minimum window width; nothing new goes there.
        let strip = try self.source("Sources/UI/AppRoot/NowPlayingPanelButtons.swift", from: self.moduleRoot)
        #expect(!strip.contains("Immersive"))
    }

    @Test("the View menu mirrors the key, opens or dismisses the window, and uses ⇧⌘I")
    func viewMenuItem() throws {
        let commands = try self.source("App/BocanCommands.swift", from: self.repoRoot)
        #expect(commands.contains("@AppStorage(\"ui.immersive.visible\") private var immersiveOpen = false"))
        #expect(commands.contains("Button(self.immersiveOpen ? \"Exit Immersive Mode\" : \"Enter Immersive Mode\")"))
        #expect(commands.contains("self.dismissWindow(id: \"immersive\")"))
        #expect(commands.contains("self.openWindow(id: \"immersive\")"))
        #expect(commands.contains(".keyboardShortcut(\"i\", modifiers: [.command, .shift])"))
    }

    @Test("the E2E seeder clears the key instead of a launch argument shadowing it")
    func seederClearsKey() throws {
        let seeder = try self.source("App/E2ESeeder.swift", from: self.repoRoot)
        #expect(seeder.contains("\"ui.immersive.visible\""))
        let session = try self.source("UITests/Support/E2ESession.swift", from: self.repoRoot)
        #expect(!session.contains("-ui.immersive.visible"))
    }
}
