import Foundation
import Testing
@testable import UI

// MARK: - ImmersiveWiringConventionTests

/// ADR-089 slice 4: Immersive Mode is wired through one preference key, one
/// overlay modifier on the root, an Esc hook ahead of drill-out, a strip
/// button, a View menu item, and the E2E seeder. Source conventions, because
/// the window, the menu bar and the key monitor cannot be exercised host-less.
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

    @Test("one preference key, owned by the overlay modifier")
    func onePreferenceKey() {
        #expect(ImmersiveOverlay.preferenceKey == "ui.immersive.visible")
    }

    @Test("the root applies the overlay to the whole window content and skips the trailing pane while immersive")
    func rootAppliesOverlay() throws {
        let root = try self.source("Sources/UI/AppRoot/RootView.swift", from: self.moduleRoot)
        #expect(root.contains(".modifier(ImmersiveOverlay(library: self.vm, lyricsVM: self.lyricsVM, visualizerVM: self.visualizerVM))"))
        #expect(root.contains("if self.immersiveVisible {"))
        #expect(root.contains("@AppStorage(ImmersiveOverlay.preferenceKey) private var immersiveVisible = false"))
    }

    @Test("Esc leaves Immersive Mode before drill-out, after the text-focus and full-screen guards")
    func escPrecedence() throws {
        let monitor = try self.source("Sources/UI/AppRoot/NavigationInputMonitor.swift", from: self.moduleRoot)
        let fullScreenGuard = try #require(monitor.range(of: "!window.styleMask.contains(.fullScreen)"))
        let immersiveExit = try #require(monitor.range(of: "if onImmersiveExit() { return true }"))
        let drillOut = try #require(monitor.range(of: "return onDrillOut()"))
        #expect(fullScreenGuard.lowerBound < immersiveExit.lowerBound)
        #expect(immersiveExit.lowerBound < drillOut.lowerBound)
        #expect(monitor.contains("@AppStorage(ImmersiveOverlay.preferenceKey) private var immersiveVisible = false"))
    }

    @Test("the toolbar toggles Immersive Mode beside the other view toggles, with an identifier and localized help")
    func toolbarButton() throws {
        let root = try self.source("Sources/UI/AppRoot/RootView.swift", from: self.moduleRoot)
        #expect(root.contains("immersiveVisible: self.$immersiveVisible"))
        let toolbar = try self.source("Sources/UI/AppRoot/MainToolbarItems.swift", from: self.moduleRoot)
        #expect(toolbar.contains(".accessibilityIdentifier(A11y.Toolbar.immersiveToggle)"))
        #expect(toolbar.contains("L10n.string(\"Toggle Immersive Mode (⇧⌘I)\")"))
        #expect(toolbar.contains("self.toggleAnimated(self.immersiveVisible)"))
        // The strip has no slack at the minimum window width; nothing new goes there.
        let strip = try self.source("Sources/UI/AppRoot/NowPlayingPanelButtons.swift", from: self.moduleRoot)
        #expect(!strip.contains("Immersive"))
    }

    @Test("the View menu mirrors the key and uses ⇧⌘I")
    func viewMenuItem() throws {
        let commands = try self.source("App/BocanCommands.swift", from: self.repoRoot)
        #expect(commands.contains("@AppStorage(\"ui.immersive.visible\") private var immersiveVisible = false"))
        #expect(commands.contains("Button(self.immersiveVisible ? \"Exit Immersive Mode\" : \"Enter Immersive Mode\")"))
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
