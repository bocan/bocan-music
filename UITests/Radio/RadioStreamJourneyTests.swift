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

    // MARK: - Helpers

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
