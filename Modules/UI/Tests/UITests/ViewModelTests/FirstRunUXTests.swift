import Foundation
import Testing
@testable import UI

// MARK: - FirstRunUXTests

/// Source-convention checks for the first-run / idle-transport polish in #310.
///
/// These behaviours live in private SwiftUI view internals (gating logic and
/// per-button styling) that can't be exercised without a full view tree, so we
/// pin the source contract the same way the VoiceOver / Dynamic Type suites do.
@Suite("First-run UX polish")
struct FirstRunUXTests {
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

    @Test("Diagnostics consent banner is deferred until the library has content (#310)")
    func consentBannerDeferredUntilContent() throws {
        let root = try self.source("AppRoot/RootView.swift")
        #expect(
            root.contains("libraryHasContent"),
            "RootView must gate DiagnosticsConsentBanner on libraryHasContent so it doesn't compete with the empty-library prompt"
        )
        // The gate must be applied where the banner is shown.
        #expect(
            root.contains("self.libraryHasContent") && root.contains("DiagnosticsConsentBanner()"),
            "The consent banner must be shown only when libraryHasContent is true"
        )
    }

    @Test("NowPlayingStrip de-emphasizes and disables Prev/Next when idle (#310)")
    func idleTransportDisabled() throws {
        // Transport controls were extracted to MusicTransportControls.swift in phase 21-10.
        let strip = try self.source("Transport/MusicTransportControls.swift")
        // Prev/Next dim to the tertiary colour and disable when nothing is loaded.
        #expect(
            strip.contains(".foregroundStyle(self.vm.title.isEmpty ? Color.textTertiary : Color.textPrimary)"),
            "Prev/Next must dim to the tertiary colour when the transport is idle"
        )
        #expect(
            strip.contains(".disabled(self.vm.title.isEmpty)"),
            "Prev/Next must be disabled when the transport is idle"
        )
    }

    @Test("Add-server URL field uses an example placeholder, not a bare scheme (#310)")
    func serverURLUsesExamplePrompt() throws {
        let view = try self.source("Settings/SubsonicSettingsView.swift")
        #expect(
            view.contains("https://music.example.com"),
            "The Server URL field must show an example-host placeholder prompt"
        )
    }
}
