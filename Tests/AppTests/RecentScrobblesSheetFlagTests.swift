import Foundation
import Testing

// MARK: - RecentScrobblesSheetFlagTests

/// Guards the cross-layer contract around the "scrobble.showRecentSheet"
/// UserDefaults key.
///
/// The key is a transient signal: the menu bar's "Show Recent Scrobbles"
/// command (App layer) sets it, and `NowPlayingStrip` (UI module) presents the
/// sheet on it. Because `@AppStorage` persists, `BocanApp.init` must clear any
/// stale value so the sheet does not reopen on the next launch. These tests
/// pin all three sides so a rename or a removed reset breaks loudly.
@Suite("Recent Scrobbles sheet flag conventions")
struct RecentScrobblesSheetFlagTests {
    private func repoRoot() -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
    }

    private func source(_ relativePath: String) throws -> String {
        let url = self.repoRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Menu command sets the shared sheet flag")
    func menuCommandUsesSharedKey() throws {
        let source = try self.source("App/BocanCommands.swift")
        #expect(
            source.contains("@AppStorage(\"scrobble.showRecentSheet\")"),
            "BocanCommands must mirror the strip's sheet flag via @AppStorage"
        )
    }

    @Test("NowPlayingStrip presents the sheet on the same key")
    func stripUsesSharedKey() throws {
        let source = try self.source("Modules/UI/Sources/UI/AppRoot/NowPlayingStrip.swift")
        #expect(
            source.contains("@AppStorage(\"scrobble.showRecentSheet\")"),
            "NowPlayingStrip must observe the same UserDefaults key the menu command sets"
        )
    }

    @Test("BocanApp clears the stale flag at launch")
    func launchClearsStaleFlag() throws {
        let source = try self.source("App/BocanApp.swift")
        #expect(
            source.contains("removeObject(forKey: \"scrobble.showRecentSheet\")"),
            "BocanApp.init must clear the persisted sheet flag so the sheet does not reopen at launch"
        )
    }
}
