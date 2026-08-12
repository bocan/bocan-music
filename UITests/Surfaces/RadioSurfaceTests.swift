import XCTest

// MARK: - RadioSurfaceTests

/// Phase 31 surface crawl: the local Radio destination. On a fixture
/// launch there are no stations, so the empty state and both add-station
/// entry points are present; each add button opens the station sheet.
@MainActor
final class RadioSurfaceTests: XCTestCase {
    private var session: E2ESession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    static let coveredIdentifiers = ["radio.emptyState", "radio.addStation"]

    /// The empty-state add button is inside a `ContentUnavailableView`,
    /// which combines its children into one element, so the inner button is
    /// not separately addressable; the toolbar add button covers the flow.
    static let skips = [
        "radio.emptyState.addStation": "inside a ContentUnavailableView that combines its children; the toolbar radio.addStation covers the add-station flow",
    ]

    func testRadioSurface() {
        let app = self.launch()
        let crawler = SurfaceCrawler(app: app)
        crawler.inv.selectSidebar("Radio")
        crawler.inv.waitFor("on Radio") { app.windows.firstMatch.title == "Radio" }

        crawler.crawl("Radio", [
            SurfaceControl("radio.emptyState", "Empty state", action: .presence) { _, inv, _ in
                inv.element("radio.emptyState").exists
            },
            SurfaceControl(
                "radio.addStation", "Add station (toolbar)",
                restore: { _, inv in inv.dismissSheet() }
            ) { app, _, _ in app.sheets.firstMatch.exists },
        ])
    }

    private func launch() -> XCUIApplication {
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        return app
    }
}
