import Foundation
import Observability

// MARK: - LaunchSanity

/// Detects unclean exits (crashes / force-quits) via a sentinel file and
/// exposes a flag the UI layer uses to show the crash-recovery banner.
///
/// Usage:
/// 1. Call `markRunning()` once, very early in `BocanApp.init()`.
/// 2. Call `markCleanExit()` from `applicationWillTerminate`.
///
/// When the app launches and the sentinel from the previous session still
/// exists it means we crashed or were force-quit.  `markRunning()` returns
/// `true` in that case and also sets `UserDefaults["launch.didCrashPreviously"]`
/// so the SwiftUI recovery banner can read it via `@AppStorage`.
@MainActor
final class LaunchSanity {
    // MARK: - Public interface

    static let shared = LaunchSanity()

    /// `@AppStorage` key read by `CrashRecoveryBanner`.
    nonisolated static let crashFlagKey = "launch.didCrashPreviously"

    // MARK: - Internals

    private let log = AppLogger.make(.app)

    private nonisolated static var sentinelURL: URL {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { fatalError("Application Support not found") }
        return base.appendingPathComponent("Bocan/.running")
    }

    private init() {}

    // MARK: - API

    /// Checks for an unclean-exit sentinel from the previous session, then
    /// writes a fresh one for the current session.
    ///
    /// - Returns: `true` when an unclean exit was detected.
    @discardableResult
    func markRunning() -> Bool {
        let url = Self.sentinelURL
        // Ensure the Bocan support directory exists.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let didCrash = FileManager.default.fileExists(atPath: url.path)
        if didCrash {
            self.log.warning("launch.unclean_exit_detected", ["sentinel": url.path])
        }

        // Stamp the sentinel with the current launch date so diagnostics can
        // correlate it with crash logs if needed.
        let stamp = Data(ISO8601DateFormatter().string(from: Date()).utf8)
        FileManager.default.createFile(atPath: url.path, contents: stamp)
        self.log.debug("launch.sentinel_written")

        // Surface to SwiftUI via AppStorage so the banner can react without
        // the UI module needing to import this App-layer type.
        UserDefaults.standard.set(didCrash, forKey: Self.crashFlagKey)

        return didCrash
    }

    /// Removes the sentinel file.  Call from `applicationWillTerminate` so
    /// a subsequent normal launch does not trigger the recovery banner.
    func markCleanExit() {
        try? FileManager.default.removeItem(at: Self.sentinelURL)
        UserDefaults.standard.set(false, forKey: Self.crashFlagKey)
        self.log.info("launch.clean_exit")
    }
}
