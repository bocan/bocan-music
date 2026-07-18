import Foundation
import Testing

// MARK: - UpdateControllerConventionTests

/// Guards the Sparkle wiring in `App/Updates/UpdateController.swift`.
///
/// Debug builds must never start the updater: a debug build's
/// `CFBundleVersion` of 1 makes every published release look like an
/// upgrade, and the shared defaults container means a "Skip This Version"
/// click in a dev session would silence the installed app's automatic
/// checks too. Sparkle cannot be exercised host-less, so this pins the
/// source contract instead.
@Suite("UpdateController conventions")
struct UpdateControllerConventionTests {
    private func source() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/Updates/UpdateController.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the updater only auto-starts in release builds")
    func updaterGatedOnDebug() throws {
        let source = try self.source()
        #expect(source.contains("#if DEBUG"), "debug builds must not start the Sparkle updater")
        #expect(
            source.contains("startingUpdater: startsUpdater"),
            "startingUpdater must flow through the DEBUG-gated flag"
        )
        #expect(
            !source.contains("startingUpdater: true"),
            "no unconditional updater start may remain"
        )
    }

    @Test("automatic checks stay Info.plist-controlled in release")
    func automaticChecksDocumented() throws {
        let source = try self.source()
        #expect(
            source.contains("SUEnableAutomaticChecks"),
            "the release-build behaviour must remain documented against the Info.plist key"
        )
    }
}
