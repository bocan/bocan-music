import XCTest

// MARK: - E2ESession

/// Owns one E2E run's identity and app launches (phase 28).
///
/// The harness cannot prepare state on disk: macOS app-container protection
/// denies the runner writes inside the app's container, and the sandbox
/// denies the app reads anywhere else. So the session only mints a run
/// identifier; the app itself builds the fixture world under its container
/// tmp when launched with `BOCAN_E2E_RUN` (see `App/E2ESeeder.swift`), and
/// sweeps stale runs on the next E2E launch.
struct E2ESession {
    /// Title tag of the first synthesized fixture tone; journeys locate the
    /// track table's first row by this text.
    static let fixtureTitle = "E2E Tone One"

    /// Per-run identifier passed as `BOCAN_E2E_RUN`.
    let runID: String

    // MARK: Well-known paths (runner's view, for diagnostics/asserts)

    /// The real user home from the passwd record. The xctrunner is itself
    /// containerized, so `homeDirectoryForCurrentUser` (and `$HOME`) point
    /// into *its* container, not the user's actual home.
    static var realUserHome: URL {
        guard let passwd = getpwuid(getuid()), let dir = passwd.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }

    /// The app's sandbox container `Data` directory for the current user.
    static var containerData: URL {
        self.realUserHome
            .appendingPathComponent(
                "Library/Containers/io.cloudcauldron.bocan/Data",
                isDirectory: true
            )
    }

    /// The real (non-E2E) Application Support tree. The isolation journey
    /// snapshots this before and after a run to prove E2E launches never
    /// touch production state.
    static var realApplicationSupport: URL {
        self.containerData.appendingPathComponent(
            "Library/Application Support",
            isDirectory: true
        )
    }

    /// This run's state directory as the runner sees it. Container
    /// protection may deny the runner even read access here; gate file
    /// assertions on readability.
    var home: URL {
        Self.containerData
            .appendingPathComponent("tmp/bocan-e2e", isDirectory: true)
            .appendingPathComponent(self.runID, isDirectory: true)
    }

    // MARK: Setup

    static func make(named name: String) -> E2ESession {
        E2ESession(runID: "\(name)-\(UUID().uuidString.prefix(8))")
    }

    // MARK: Launch

    /// Launches the app under this run's identity. Extra environment
    /// (e.g. `BOCAN_E2E_SEED_RADIO_URL`) and argument-domain defaults
    /// overrides (e.g. `["-playback.resumePosition", "412"]`) layer on per
    /// launch. Reusing the session across launches exercises persistence.
    @MainActor
    func launch(
        environment: [String: String] = [:],
        arguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BOCAN_E2E_RUN"] = self.runID
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        // Deterministic launch state, pinned via the argument domain so a
        // developer's real preferences (and prior tests) never leak in:
        //
        // - `-ApplePersistenceIgnoreState YES` suppresses macOS scene
        //   restoration, and `-ui.windowMode.miniPlayerOpen NO` stops the
        //   app's own `restoreIfNeeded()` from reopening the mini player.
        //   Either path can order out the main window before its bootstrap
        //   `.task` runs, wedging the launch so no fixtures ever scan. (The
        //   argument domain shadows reads without blocking a live in-test
        //   toggle, which writes the property directly.)
        // - `-sync.enabled NO` keeps the Phone Sync Bonjour server from
        //   starting, which otherwise raises a modal macOS "find devices on
        //   your local network" permission dialog that blocks every UI
        //   interaction underneath it.
        // - `-lyrics.paneVisible NO` / `-visualizer.paneVisible NO`: an
        //   earlier, unrelated test (e.g. a menu crawl toggling "Show
        //   Lyrics") leaves its pane open in the real, un-isolated
        //   `UserDefaults.standard` these view models read directly — the
        //   next run then launches with a stale pane already showing
        //   (phase 33 found this via the visualizer suite: a prior lyrics
        //   toggle from an earlier test made a fresh launch open Lyrics
        //   instead of nothing).
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-ui.windowMode.miniPlayerOpen", "NO",
            "-sync.enabled", "NO",
            "-lyrics.paneVisible", "NO",
            "-visualizer.paneVisible", "NO",
        ] + arguments
        app.launch()
        return app
    }
}

// MARK: - Test-name sanitising

extension String {
    /// "-[FoundationJourneys testX]" to a filesystem-friendly "testX".
    var sanitizedTestName: String {
        self.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .last ?? "run"
    }
}

// MARK: - XCUIApplication conveniences

@MainActor
extension XCUIApplication {
    /// The transport play/pause button. Its accessibility label mirrors
    /// state: "Play" when idle or paused, "Pause" while playing.
    var playPauseButton: XCUIElement {
        self.buttons["nowPlayingStrip.playPause"]
    }

    /// Waits until the transport reports playing state.
    func waitUntilPlaying(timeout: TimeInterval) -> Bool {
        self.waitUntilPlayPauseLabel(is: "Pause", timeout: timeout)
    }

    /// Waits until the transport reports paused/stopped state.
    func waitUntilNotPlaying(timeout: TimeInterval) -> Bool {
        self.waitUntilPlayPauseLabel(is: "Play", timeout: timeout)
    }

    private func waitUntilPlayPauseLabel(is expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if self.playPauseButton.exists, self.playPauseButton.label == expected {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    /// The first seeded track's title cell. The track table is an AppKit
    /// `NSTableView` inside an `NSViewRepresentable` whose row topology is
    /// not stable under XCUITest queries, so target the deterministic
    /// fixture title text instead; double-clicking it hits the row. Formal
    /// page objects arrive with the phase 29 identifier audit.
    var firstTrackRow: XCUIElement {
        self.staticTexts[E2ESession.fixtureTitle]
    }

    /// Waits until the library scan has produced at least one visible track
    /// row. Fresh-scan latency dominates here, so the timeout is generous.
    func waitForTrackRows(timeout: TimeInterval) -> Bool {
        self.firstTrackRow.waitForExistence(timeout: timeout)
    }
}
