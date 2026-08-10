import Foundation

// MARK: - E2EEnvironment

/// The single reader of the whole-app test environment (phase 28). No other
/// file may consult these variables directly; everything E2E-conditional in
/// the app routes through here so the production behaviour is auditable in
/// one place.
///
/// The contract is a run *identifier*, not a path: macOS app-container
/// protection stops the test runner from writing inside this app's
/// container, and the sandbox stops this app from reading anywhere else. So
/// the harness passes `BOCAN_E2E_RUN=<id>` and the app builds its own
/// fixture world under its container tmp (see `E2ESeeder`). Sparkle needs
/// no gating: it already never starts in DEBUG.
enum E2EEnvironment {
    /// Opaque per-run identifier; its presence activates E2E mode. Reduced
    /// to a single path component so it can never escape the runs root.
    static var runID: String? {
        ProcessInfo.processInfo.environment["BOCAN_E2E_RUN"]
            .map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    static var isActive: Bool {
        self.runID != nil
    }

    /// Root of all E2E run homes. `NSTemporaryDirectory()` resolves inside
    /// the app's own container under the sandbox, so this is always
    /// app-writable and never overlaps real Application Support.
    static var runsRoot: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bocan-e2e", isDirectory: true)
    }

    /// This run's state directory, or nil in normal operation.
    static var home: URL? {
        self.runID.map { self.runsRoot.appendingPathComponent($0, isDirectory: true) }
    }

    /// The re-rooted database file for this run.
    static var databaseURL: URL? {
        self.home?.appendingPathComponent("bocan.sqlite")
    }

    /// The synthesized fixture library added as a library root on launch,
    /// so tests never have to drive `NSOpenPanel`.
    static var seedDirectory: URL? {
        self.home?.appendingPathComponent("Music", isDirectory: true)
    }

    /// When set, the launch seeds the playback queue with a single internet
    /// radio item pointing at this URL (the harness's stalling listener),
    /// so a relaunch exercises the persisted-radio-queue restore path (the
    /// phase 27 launch-wedge regression).
    static var seedRadioQueueURL: URL? {
        guard self.isActive else { return nil }
        return ProcessInfo.processInfo.environment["BOCAN_E2E_SEED_RADIO_URL"]
            .flatMap(URL.init(string:))
    }
}
