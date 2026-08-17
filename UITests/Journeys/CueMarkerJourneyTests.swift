import XCTest

// MARK: - CueMarkerJourneyTests

/// ADR-087 end to end: the seeder writes a single-file rip (one tone plus a
/// sidecar cue naming markers at 0/20/40s), the initial scan attaches the
/// markers automatically, and the transport walks them — forward jumps
/// marker to marker inside the same track, and past the last marker the
/// queue advances to the next track as always.
@MainActor
final class CueMarkerJourneyTests: XCTestCase {
    private var session: E2ESession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    override func tearDownWithError() throws {
        self.session = nil
    }

    /// The marker line text, wherever XCTest bridges it (`.updatesFrequently`
    /// routes text through `.value` on some macOS builds — see the
    /// label/value bridging note in the test support docs).
    private func markerLine(in app: XCUIApplication, _ inv: MenuInvoker) -> String? {
        let element = app.descendants(matching: .any)["nowPlayingStrip.markerLine"].firstMatch
        guard element.exists else { return nil }
        if let value = element.value as? String, !value.isEmpty { return value }
        let label = element.label
        return label.isEmpty ? nil : label
    }

    func testMarkersNavigateWithinTheTrackThenAdvance() {
        // The cue fixture is opt-in: the rest of the suite is calibrated to
        // the two-tone world, so only this journey grows the third album.
        let app = self.session.launch(environment: ["BOCAN_E2E_CUE_FIXTURE": "1"])
        defer { app.terminate() }
        let inv = MenuInvoker(app: app)

        XCTAssertTrue(
            app.waitForTrackRows(timeout: 60),
            "Expected the seeded fixture library to scan into the track table"
        )

        // Play the cue album. Plain double-click queues the surrounding
        // browse context; the cue album's neighbours in that order are not
        // pinned here (the fixtures tie on every sort key), so the final
        // assertion checks "leaves the cue track" rather than a specific
        // successor.
        let cueRow = app.staticTexts["E2E Cue Album"].firstMatch
        XCTAssertTrue(cueRow.waitForExistence(timeout: 10), "the cue album track never appeared")
        cueRow.doubleClick()
        XCTAssertTrue(app.waitUntilPlaying(timeout: 10), "playback never started")

        // The scanner attached the markers; playback starts inside the first.
        inv.waitFor("the first marker line appears", timeout: 15) {
            self.markerLine(in: app, inv)?.contains("Marker One") == true
        }

        // Forward walks the markers without leaving the track.
        app.buttons["nowPlayingStrip.next"].firstMatch.click()
        inv.waitFor("forward jumps to the second marker", timeout: 10) {
            self.markerLine(in: app, inv)?.contains("Marker Two") == true
        }
        app.buttons["nowPlayingStrip.next"].firstMatch.click()
        inv.waitFor("forward jumps to the third marker", timeout: 10) {
            self.markerLine(in: app, inv)?.contains("Marker Three") == true
        }
        XCTAssertTrue(app.waitUntilPlaying(timeout: 5), "marker jumps must not interrupt playback")

        // Past the last marker, next behaves exactly as track-next always
        // has: advance to the queue's next item, or stop at its end. Either
        // way the cue track is left and the marker line goes with it.
        app.buttons["nowPlayingStrip.next"].firstMatch.click()
        inv.waitFor("past the last marker the transport leaves the cue track", timeout: 10) {
            let title = inv.value("nowPlayingStrip.title.button")
            let stopped = app.playPauseButton.exists && app.playPauseButton.label == "Play"
            return title != "E2E Cue Album" || stopped
        }
        inv.waitFor("the marker line disappears with the cue track", timeout: 5) {
            self.markerLine(in: app, inv) == nil
        }
    }
}
