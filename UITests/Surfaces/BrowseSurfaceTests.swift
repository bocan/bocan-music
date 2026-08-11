import XCTest

// MARK: - BrowseSurfaceTests

/// Phase 31 surface crawls for the browse destinations: the Songs track
/// table (double-click to play) and the Albums grid (tile opens the album
/// detail). Each surface's identified controls are exercised with a
/// concrete postcondition. Includes the Esc / mouse-back navigation
/// invariants from every drill-down.
@MainActor
final class BrowseSurfaceTests: XCTestCase {
    private var session: E2ESession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    static let songsCoveredIdentifiers = ["tracksTable"]
    static let albumsCoveredIdentifiers = ["albumsGrid", "albumsGrid.tile.1"]

    // MARK: Songs

    /// The Songs track table: present, and double-clicking a row starts
    /// playback (the surface's core interaction contract).
    func testSongsSurface() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        inv.selectSidebar("Songs")

        XCTAssertTrue(
            inv.element("tracksTable").waitForExistence(timeout: 6),
            "[Songs] tracksTable is missing"
        )
        app.firstTrackRow.doubleClick()
        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "[Songs] double-click did not start playback")
    }

    // MARK: Albums

    /// The Albums grid: the grid and its first tile are present, and
    /// single-clicking the tile opens the album detail. Then the Esc and
    /// mouse-back navigation invariants are re-proven from the drill-down.
    func testAlbumsSurface() {
        let app = self.launch()
        let crawler = SurfaceCrawler(app: app)
        crawler.inv.selectSidebar("Albums")
        crawler.inv.waitFor("on Albums") { app.windows.firstMatch.title == "Albums" }

        crawler.crawl("Albums", [
            SurfaceControl("albumsGrid", "Albums grid", action: .presence) { _, inv, _ in
                inv.element("albumsGrid").exists
            },
            SurfaceControl(
                "albumsGrid.tile.1", "Album tile (open)",
                restore: { _, inv in inv.selectSidebar("Albums") }
            ) { app, _, _ in app.buttons["Shuffle Album"].waitForExistence(timeout: 5) },
        ])

        self.assertDrillOutInvariants(app, crawler.inv)
    }

    /// From an opened album detail, Esc and mouse-back (⌘[) each return to
    /// the Albums grid (the phase 27 / #378 navigation contract).
    private func assertDrillOutInvariants(_ app: XCUIApplication, _ inv: MenuInvoker) {
        // Drill in again.
        inv.element("albumsGrid.tile.1").click()
        inv.waitFor("album detail open (Esc case)") { app.buttons["Shuffle Album"].exists }
        app.typeKey(.escape, modifierFlags: [])
        inv.waitFor("Esc drills out to the grid") { inv.element("albumsGrid").exists && !app.buttons["Shuffle Album"].exists }

        inv.element("albumsGrid.tile.1").click()
        inv.waitFor("album detail open (back case)") { app.buttons["Shuffle Album"].exists }
        app.typeKey("[", modifierFlags: .command)
        inv.waitFor("mouse-back drills out to the grid") { inv.element("albumsGrid").exists && !app.buttons["Shuffle Album"].exists }
    }

    // MARK: Helpers

    private func launch() -> XCUIApplication {
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        return app
    }
}
