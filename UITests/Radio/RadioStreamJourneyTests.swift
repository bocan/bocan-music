import XCTest

// MARK: - RadioStreamJourneyTests

/// Phase 34: radio journeys against `E2EStreamServer`, a loopback fake ICY
/// station — the first tier of E2E coverage that exercises a real internet
/// radio connection (add, play, live title updates, stream details) without
/// ever touching the internet.
@MainActor
final class RadioStreamJourneyTests: XCTestCase {
    private var session: E2ESession!
    private var server: E2EStreamServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
        self.server = try E2EStreamServer(
            stationName: "E2E Dial FM",
            genre: "Test Genre",
            initialTitle: "Opening Theme"
        )
    }

    override func tearDown() {
        self.server?.stop()
        super.tearDown()
    }

    // MARK: - Add by URL

    /// Pastes the fake station's stream URL into Add Station, plays it, and
    /// asserts the transport strip shows the scripted live ICY title with
    /// the station name on the artist line — proof the whole pipeline
    /// (E2EStreamServer's wire format -> FFmpeg's ICY reader -> AudioEngine
    /// -> NowPlayingViewModel) works end to end.
    func testAddByURLPlaysAndShowsScriptedTitle() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        self.openRadio(app, inv)

        self.addStation(app, inv, name: "E2E Dial FM", streamURL: self.server.streamURL.absoluteString)

        let row = app.staticTexts["E2E Dial FM"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the newly added station never appeared in the list")
        row.doubleClick()

        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "the fake stream never started playing")

        // The title element carries `.accessibilityAddTraits(.updatesFrequently)`
        // (NowPlayingStrip.swift), which bridges its live text to `.value`
        // rather than `.label` regardless of which modifier set it (found
        // via an AX tree dump). The artist element is a plain navigation
        // button labelled "Go to artist <name>", not the bare name, so
        // match by substring instead of equality.
        inv.waitFor("strip shows the scripted ICY title", timeout: 20) {
            inv.value("nowPlayingStrip.title.button") == "Opening Theme"
        }
        let artistLabel = inv.label("nowPlayingStrip.subtitle.button") ?? ""
        XCTAssertTrue(artistLabel.contains("E2E Dial FM"), "artist label was \"\(artistLabel)\"")
    }

    // MARK: - Stream details

    /// While playing, opens the info sheet from the transport strip and
    /// asserts the live decoder facts match the fixture, including
    /// "Now-Playing Titles: Supported" (`supportsIcyMetadata`) — only
    /// reliable once a real `StreamTitle` has actually landed, per
    /// `StreamDetails.withObservedTitles()`. Then plays a library track
    /// instead — there is no user-facing "Stop" for radio, and pausing
    /// leaves the station as the current queue item — and reopens the
    /// same station's info from its catalog row (the only path once it's
    /// no longer current) to assert it shows what was captured on
    /// connect, offline.
    func testStreamDetailsShowLiveFactsThenPersistedProfileOffline() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        self.openRadio(app, inv)
        self.addStation(app, inv, name: "E2E Dial FM", streamURL: self.server.streamURL.absoluteString)

        let row = app.staticTexts["E2E Dial FM"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.doubleClick()
        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "the fake stream never started playing")
        inv.waitFor("strip shows the scripted ICY title", timeout: 20) {
            inv.value("nowPlayingStrip.title.button") == "Opening Theme"
        }

        inv.element("nowPlayingStrip.info").click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5), "info sheet never opened")
        // These rows carry `.textSelection(.enabled)`, which — like the
        // strip's updatesFrequently title — bridges content to `.value`
        // rather than `.label` (found empirically).
        XCTAssertEqual(inv.value("radio.info.value.nowPlayingTitles"), "Supported")
        self.assertNotNilAndNotEmpty(inv.value("radio.info.value.codec"), "live codec must be shown while playing")
        self.assertNotNilAndNotEmpty(
            inv.value("radio.info.value.sampleRate"),
            "live sample rate must be shown while playing"
        )
        inv.element("radio.info.close").click()
        inv.waitFor("info sheet closes") { !app.sheets.firstMatch.exists }

        // Pausing the same station leaves it the current queue item —
        // `nowPlayingRadioStreamURL` stays set, so `liveDetails` stays
        // non-nil (found empirically: there is no user-facing "Stop"
        // action for radio, only pause). Playing a library track instead
        // genuinely clears the station as current, the same way it would
        // for a real user browsing away to something else.
        inv.selectSidebar("Songs")
        app.firstTrackRow.doubleClick()
        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "the library track never started playing")

        inv.selectSidebar("Radio")
        inv.waitFor("on Radio") { app.windows.firstMatch.title == "Radio" }
        XCTAssertTrue(app.staticTexts["E2E Dial FM"].waitForExistence(timeout: 5))
        self.openRowInfo(app, inv)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5), "row info sheet never opened")
        XCTAssertNil(
            inv.value("radio.info.value.nowPlayingTitles"),
            "Now-Playing Titles only applies to a live connection; must be absent once stopped"
        )
        self.assertNotNilAndNotEmpty(
            inv.value("radio.info.value.codec"),
            "the persisted profile must still show the codec"
        )
        self.assertNotNilAndNotEmpty(
            inv.value("radio.info.value.lastConnected"),
            "the persisted profile must show when the station last connected"
        )
    }

    /// `XCTAssertNotNil` alone would pass on an empty string, which is
    /// exactly the wrong-property symptom (`.label` on a `.value`-bridged
    /// element) this suite already found once; require real content.
    private func assertNotNilAndNotEmpty(
        _ value: String?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(!(value ?? "").isEmpty, message, file: file, line: line)
    }

    // MARK: - Helpers

    /// Opens the catalog row's info sheet via its right-click "Get Info"
    /// context menu item — the first item in that menu
    /// (`RadioView.swift`). A synthetic `.hover()` never reliably revealed
    /// the row's hover-only info button in testing — a `List` row is
    /// `NSTableView`-backed, unlike the plain-view hover targets that
    /// worked directly elsewhere in this suite (found empirically) — so
    /// "Get Info" was added to the row's context menu as a real,
    /// hover-independent entry point (also useful for keyboard/rotor
    /// users, not just automation). Right-click is a raw mouse event
    /// synthesized at a screen coordinate, so it reaches the real row view
    /// regardless of `.accessibilityElement(children: .combine)`. Selects
    /// the item by keyboard rather than `app.menuItems["Get Info"]`: that
    /// label is reused across several other context/menu-bar items
    /// elsewhere in the app (Artists, Track Table, Queue, Podcasts, the
    /// Track menu), so the query matches more than one element.
    private func openRowInfo(_ app: XCUIApplication, _ inv: MenuInvoker) {
        inv.elementWithIdentifierPrefix("radio.row.").rightClick()
        inv.settle(0.3)
        app.typeKey(.downArrow, modifierFlags: [])
        inv.settle(0.2)
        app.typeKey(.return, modifierFlags: [])
        inv.settle(0.3)
    }

    private func openRadio(_ app: XCUIApplication, _ inv: MenuInvoker) {
        inv.selectSidebar("Radio")
        inv.waitFor("on Radio") { app.windows.firstMatch.title == "Radio" }
    }

    /// Drives the add-station sheet's form stage to completion; the sheet
    /// dismisses on success (a `.saved` `AddResolution`). Leaves the
    /// playlist-indirection (`.found`) case to its own journey.
    private func addStation(_ app: XCUIApplication, _ inv: MenuInvoker, name: String, streamURL: String) {
        inv.element("radio.addStation").click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5), "add-station sheet never opened")

        let nameField = inv.element("radio.sheet.name")
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        inv.pasteText(name, into: nameField)

        inv.pasteText(streamURL, into: inv.element("radio.sheet.streamURL"))

        inv.element("radio.sheet.submit").click()
        inv.waitFor("add-station sheet dismisses") { !app.sheets.firstMatch.exists }
    }

    private func launch() -> XCUIApplication {
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        return app
    }
}
