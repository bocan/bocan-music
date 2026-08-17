import Foundation
import Scrobble

// MARK: - E2EEnvironment

/// The single reader of the whole-app test environment (ADR-079). No other
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

    // MARK: Settings isolation (ADR-083)

    /// The per-run `UserDefaults` suite name backing the Settings scene in
    /// E2E. Deriving it from the run id keeps every run isolated from the
    /// others and from the real `.standard` domain, while a relaunch that
    /// reuses the run id reads the same suite so persistence is testable.
    static func settingsSuiteName(forRunID runID: String) -> String {
        "io.cloudcauldron.bocan.e2e.\(runID)"
    }

    /// This run's Settings `UserDefaults` suite, or nil in normal operation.
    /// The Settings scene routes its `@AppStorage` through this so a test can
    /// flip a preference and prove it survives a relaunch, without ever
    /// touching the developer's real preferences (the isolation decision the
    /// ADR-083 spec calls out).
    static var settingsDefaults: UserDefaults? {
        self.runID
            .map { self.settingsSuiteName(forRunID: $0) }
            .flatMap { UserDefaults(suiteName: $0) }
    }

    /// The Keychain service name scrobble credentials are stored under in
    /// E2E mode, isolated from the developer's real `Credentials.defaultService`
    /// namespace: unlike the library/Subsonic/podcast state (re-rooted SQLite)
    /// and Settings (a per-run `UserDefaults` suite), scrobble tokens live in
    /// the real login Keychain with no isolation of their own -- so a `Scrobble
    /// Service`'s "now playing" ping (fired on every track start, unlike a full
    /// scrobble, which needs 30s+ of playback) would read the developer's own
    /// real Last.fm/ListenBrainz/Rocksky session and ping those live services
    /// with fixture track titles. One fixed name (not per-run) is enough: no
    /// E2E journey ever connects a scrobble account, so nothing ever writes to
    /// it -- it stays permanently empty, just isolated from the real one.
    static var scrobbleCredentialsService: String {
        self.isActive ? "io.cloudcauldron.bocan.scrobble.e2e" : Credentials.defaultService
    }

    /// When set, `E2ESeeder` adds the ADR-087 cue fixture (a third tone plus
    /// a sidecar cue sheet) to the seed library. Opt-in per journey: the rest
    /// of the suite is calibrated to the two-tone world (selection counts,
    /// queue lengths), so only the marker journey requests it.
    static var cueFixtureRequested: Bool {
        self.isActive && ProcessInfo.processInfo.environment["BOCAN_E2E_CUE_FIXTURE"] != nil
    }

    /// When set, the launch seeds the playback queue with a single internet
    /// radio item pointing at this URL (the harness's stalling listener),
    /// so a relaunch exercises the persisted-radio-queue restore path (the
    /// ADR-078 launch-wedge regression).
    static var seedRadioQueueURL: URL? {
        guard self.isActive else { return nil }
        return ProcessInfo.processInfo.environment["BOCAN_E2E_SEED_RADIO_URL"]
            .flatMap(URL.init(string:))
    }

    /// When set, `E2ESeeder` writes a one-station `.m3u` dial file into this
    /// run's home pointing at this URL, so the Import Playlist… journey can
    /// drive a real `NSOpenPanel` to a file the app can actually read: the
    /// runner cannot write inside this app's container, and the sandbox
    /// stops this app reading anywhere else (same contract as `home` above).
    static var dialFileStreamURL: URL? {
        guard self.isActive else { return nil }
        return ProcessInfo.processInfo.environment["BOCAN_E2E_DIAL_FILE_URL"]
            .flatMap(URL.init(string:))
    }

    /// Where `E2ESeeder` writes the dial file described above.
    static var dialFileURL: URL? {
        self.home?.appendingPathComponent("dial.m3u")
    }
}
