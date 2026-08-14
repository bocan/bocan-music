import XCTest

// MARK: - PodcastJourneyTests

/// Phase 34: podcast journeys against `E2EPodcastServer`, a loopback fake
/// podcast host — subscribe by URL, download + play with resume across a
/// relaunch, and refresh discovering newly published content.
@MainActor
final class PodcastJourneyTests: XCTestCase {
    private var session: E2ESession!
    private var server: E2EPodcastServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
        // Long enough that a single 30s skip-forward (the resume journey)
        // lands well short of the natural end.
        self.server = try E2EPodcastServer(showTitle: "E2E Test Cast", episodeSeconds: 60)
    }

    override func tearDown() {
        self.server?.stop()
        super.tearDown()
    }

    // MARK: - Subscribe + episode list

    func testSubscribeByURLRendersEpisodeList() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        self.subscribeAndOpenShow(app, inv)

        XCTAssertTrue(app.staticTexts["Episode One"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Episode Two"].exists)
        XCTAssertFalse(app.staticTexts["Episode Three"].exists, "the third episode is not published yet")
    }

    // MARK: - Download, play, resume across a relaunch

    func testDownloadAndPlayWithResumeAcrossRelaunch() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        self.subscribeAndOpenShow(app, inv)

        XCTAssertTrue(app.staticTexts["Episode One"].waitForExistence(timeout: 10))
        app.staticTexts["Episode One"].rightClick()
        inv.settle(0.3)
        app.menuItems["Download"].click()

        // Re-query fresh on every poll: a captured row reference can go
        // stale once its download-state icon re-renders (found the hard
        // way with radio rows re-rendering on their own hover state).
        inv.waitFor("episode one finishes downloading", timeout: 30) {
            app.staticTexts["Episode One"].rightClick()
            inv.settle(0.2)
            let downloaded = app.menuItems["Remove Download"].exists
            inv.pressEscape()
            return downloaded
        }

        app.staticTexts["Episode One"].doubleClick()
        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "the downloaded episode never started playing")

        app.buttons["nowPlayingStrip.skipForward"].click()
        // Outlive the podcast position write-back's ~5s tick
        // (QueuePlayer.startScrobbleUpdateLoop) so the skip is on disk
        // before the force-quit below.
        inv.settle(7)
        let positionAfterSkip = inv.value("nowPlayingStrip.scrubber")
        XCTAssertNotNil(positionAfterSkip)
        XCTAssertFalse(positionAfterSkip?.hasPrefix("0:00") ?? true, "skip-forward must actually advance the position")

        app.terminate()
        let relaunched = self.session.launch(arguments: MenuManifest.matrixDefaults)
        // The harness's terminate() is a force-quit, so relaunch shows the
        // crash-recovery banner (FoundationJourneys.testRadioQueueRestoreDoesNotWedgePlayback).
        let recover = relaunched.buttons["Keep the restored queue"].firstMatch
        if recover.waitForExistence(timeout: 15) {
            recover.click()
        }

        inv.waitFor("the episode restores into Now Playing", timeout: 15) {
            inv.value("nowPlayingStrip.title.button") == "Episode One"
        }
        if relaunched.playPauseButton.label == "Play" {
            relaunched.playPauseButton.click()
        }
        inv.waitFor("the resumed position is honored", timeout: 10) {
            !(inv.value("nowPlayingStrip.scrubber")?.hasPrefix("0:00") ?? true)
        }
    }

    // MARK: - Refresh discovers new content

    func testRefreshDiscoversNewEpisode() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        self.subscribeAndOpenShow(app, inv)

        XCTAssertTrue(app.staticTexts["Episode One"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Episode Three"].exists)

        self.server.publishThirdEpisode()

        // A SwiftUI `Menu` surfaces as a menuButton, not a plain button.
        inv.element("podcasts.show.moreMenu").click()
        inv.settle(0.3)
        app.menuItems["Refresh"].click()

        inv.waitFor("the newly published episode appears", timeout: 15) {
            app.staticTexts["Episode Three"].exists
        }
    }

    // MARK: - Helpers

    private func launch() -> XCUIApplication {
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        return app
    }

    /// Subscribes to `self.server`'s feed via the real add-bar -> detail
    /// sheet flow, then opens the show's episode list. `.pasteText` (not
    /// `.typeText`, which silently drops colons — found the hard way in the
    /// radio journeys) carries the `http://127.0.0.1:PORT/...` feed URL.
    private func subscribeAndOpenShow(_ app: XCUIApplication, _ inv: MenuInvoker) {
        inv.selectSidebar("Podcasts")
        inv.waitFor("on Podcasts") { app.windows.firstMatch.title == "Podcasts" }

        let field = inv.element("podcasts.addBar.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        inv.pasteText(self.server.feedURL.absoluteString, into: field)

        let addByURLRow = inv.element("podcasts.addByURLRow")
        XCTAssertTrue(addByURLRow.waitForExistence(timeout: 5), "the add-by-URL row never appeared")
        addByURLRow.click()

        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5), "the podcast detail sheet never opened")
        let subscribeButton = inv.element("podcasts.detail.subscribe")
        XCTAssertTrue(subscribeButton.waitForExistence(timeout: 10), "the subscribe button never appeared")
        subscribeButton.click()
        inv.waitFor("subscribing flips the button to Subscribed") { !subscribeButton.exists }

        // Scoped to the sheet: the main window's own toolbar back-navigation
        // chevron may share this label.
        app.sheets.firstMatch.buttons["Back"].click()
        inv.waitFor("the detail sheet dismisses") { !app.sheets.firstMatch.exists }

        // Nothing clears the add-bar text on subscribe, so the results panel
        // (still showing "Add this feed" for the same URL) stays in front of
        // the grid until the search is cleared -- same as a real user would
        // need to do to see their subscribed shows.
        inv.element("podcasts.addBar.clear").click()

        let showTile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "E2E Test Cast"))
            .firstMatch
        XCTAssertTrue(showTile.waitForExistence(timeout: 10), "the subscribed show never appeared in the grid")
        showTile.click()
    }
}
