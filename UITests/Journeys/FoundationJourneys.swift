import XCTest

// MARK: - FoundationJourneys

/// Phase 28 foundation journeys: prove the E2E harness can launch the app in
/// an isolated fixture world, drive real playback, and re-run the phase 27
/// launch-wedge scenario end to end. Later phases build on these primitives.
@MainActor
final class FoundationJourneys: XCTestCase {
    private var session: E2ESession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    override func tearDownWithError() throws {
        // No filesystem teardown: the runner cannot delete inside the app's
        // container. The app sweeps stale run homes on its next E2E launch.
        self.session = nil
    }

    // MARK: Journey 1: cold launch, seeded library, isolation

    /// Cold-launches into a fixture home and waits for the seeded library
    /// to scan in.
    ///
    /// Isolation from real state is structural rather than asserted here:
    /// every E2E path in the app keys off the same `BOCAN_E2E_RUN` check,
    /// so a broken re-root also disables seeding and fails this journey at
    /// the track-rows wait. The runner cannot verify by reading files:
    /// macOS container protection parks any `open(2)` inside another app's
    /// container on a TCC consent that never arrives unattended (`stat` is
    /// allowed, which is why the `fileExists` check below is safe).
    func testColdLaunchShowsSeededLibrary() {
        let app = self.session.launch()
        defer { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 15),
            "Expected the main window within 15s of an E2E launch"
        )
        XCTAssertTrue(
            app.waitForTrackRows(timeout: 60),
            "Expected the seeded fixture library to scan into the track table"
        )

        let database = self.session.home.appendingPathComponent("bocan.sqlite")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: database.path),
            "Expected the database to be re-rooted into the E2E home"
        )
    }

    // MARK: Journey 2: play and pause a seeded track

    /// Double-clicks the first seeded track and verifies the transport
    /// reaches playing state, then pauses it again.
    func testPlayAndPauseASeededTrack() {
        let app = self.session.launch()
        defer { app.terminate() }

        XCTAssertTrue(
            app.waitForTrackRows(timeout: 60),
            "Expected the seeded fixture library to scan into the track table"
        )
        app.firstTrackRow.doubleClick()
        XCTAssertTrue(
            app.waitUntilPlaying(timeout: 10),
            "Expected playback to start within 10s of double-clicking a track"
        )
        app.playPauseButton.click()
        XCTAssertTrue(
            app.waitUntilNotPlaying(timeout: 5),
            "Expected playback to pause after clicking the transport button"
        )
    }

    // MARK: Journey 3: the phase 27 launch-wedge regression

    /// Launch #1 persists a queue holding a radio station whose "server"
    /// accepts connections but never responds. Launch #2 restores that queue
    /// with a saved resume position, exactly the state that wedged the app in
    /// phase 27 (a live-stream seek at server pace holding the transport
    /// gate). The app must stay responsive: a local track has to play within
    /// seconds of the relaunch.
    func testRadioQueueRestoreDoesNotWedgePlayback() throws {
        let listener = try StallingListener()
        defer { listener.stop() }

        let first = self.session.launch(
            environment: ["BOCAN_E2E_SEED_RADIO_URL": listener.url.absoluteString]
        )
        XCTAssertTrue(
            first.waitForTrackRows(timeout: 60),
            "Expected the seeded fixture library to scan in during launch #1"
        )
        // The queue save is debounced by 2s; outlive it so the seeded radio
        // queue is on disk before termination.
        Thread.sleep(forTimeInterval: 4)
        first.terminate()

        let second = self.session.launch(
            arguments: ["-playback.resumePosition", "412"]
        )
        defer { second.terminate() }

        // The harness's terminate() is a force-quit, so launch #2 rightly
        // shows the crash-recovery banner. Keep the restored queue; rows
        // under the banner's inset don't materialize until it dismisses.
        let recover = second.buttons["Keep the restored queue"].firstMatch
        XCTAssertTrue(
            recover.waitForExistence(timeout: 15),
            "Expected the crash-recovery banner after a force-quit"
        )
        recover.click()

        // Non-vacuity guard: launch #2 must actually restore the radio
        // queue, or this test proves nothing about the wedge path. The
        // strip intentionally shows "Not playing" for a restored live
        // stream (no position to resume), so look in Up Next instead: its
        // slice starts at the playhead, so the restored current item is
        // its first row.
        let upNext = second.staticTexts["Up Next"].firstMatch
        XCTAssertTrue(
            upNext.waitForExistence(timeout: 15),
            "Expected the sidebar's Up Next row after relaunch"
        )
        upNext.click()
        // Queue rows are single accessibility elements with a composed label
        // ("Now playing: <title>, <artist>, <duration>"), so match by
        // substring rather than an exact static text.
        let wedgeRow = second.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "E2E Wedge FM"))
            .firstMatch
        XCTAssertTrue(
            wedgeRow.waitForExistence(timeout: 15),
            "Expected the persisted radio queue to restore into Up Next"
        )

        second.staticTexts["Songs"].firstMatch.click()
        XCTAssertTrue(
            second.waitForTrackRows(timeout: 60),
            "Expected the library to be present on relaunch"
        )
        second.firstTrackRow.doubleClick()
        XCTAssertTrue(
            second.waitUntilPlaying(timeout: 10),
            "Playback did not start after restoring a radio queue: the phase 27 launch wedge is back"
        )
    }
}

// MARK: - Test-name sanitising

private extension String {
    /// "-[FoundationJourneys testX]" to a filesystem-friendly "testX".
    var sanitizedTestName: String {
        self.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .last ?? "run"
    }
}
