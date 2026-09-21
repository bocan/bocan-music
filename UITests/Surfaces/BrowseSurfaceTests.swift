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

    override func setUp() async throws {
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

    // MARK: Recently Added

    /// The Recently Added Recents destination is populated with the fixtures
    /// (freshly imported), sharing the Songs track-table contract:
    /// double-clicking a row plays. An interaction test (it reuses the
    /// `tracksTable` identifier already owned by the Songs surface).
    func testRecentlyAddedSurface() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        inv.selectSidebar("Recently Added")

        XCTAssertTrue(
            inv.element("tracksTable").waitForExistence(timeout: 6),
            "[Recently Added] tracksTable is missing"
        )
        inv.waitFor("fixtures appear in Recently Added") { inv.visibleFixtureTitleCount() == 2 }
        app.firstTrackRow.doubleClick()
        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "[Recently Added] double-click did not play")
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

    // MARK: Track context menu

    /// Right-clicking a track in an album opened from the grid must raise the
    /// track menu, with no left-click on the table first. A tile click focuses
    /// the tile, and a grid torn down while holding focus left SwiftUI's window
    /// consuming every right-click, so the table never saw one. The route
    /// matters: the same page reached by Go to Album never had the fault, and
    /// one left-click on a row cured it, which is why it looked intermittent.
    func testTrackContextMenuOpensInsideAnAlbum() {
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        let inv = MenuInvoker(app: app)

        // The Albums grid, then a tile. A plain click on the row element, not
        // the coordinate tap `selectSidebar` uses, which does not navigate.
        app.activate()
        let albumsRow = app.descendants(matching: .any).matching(identifier: "sidebar.albums").firstMatch
        albumsRow.click()
        XCTAssertTrue(inv.element("albumsGrid").waitForExistence(timeout: 8), "never reached the Albums grid")
        inv.element("albumsGrid.tile.1").click()
        inv.waitFor("album detail open") { app.buttons["Shuffle Album"].exists }

        var outcomes: [String] = []
        func probe(_ phase: String) {
            for title in [E2ESession.fixtureTitle, "E2E Tone Two", E2ESession.fixtureTitle] {
                app.staticTexts[title].rightClick()
                // "Re-scan File" exists only in the context menu. "Play Now"
                // is also a menu bar item, always in the tree, so waiting on
                // it passes whether or not the context menu came up.
                let opened = app.menuItems["Re-scan File"].waitForExistence(timeout: 3)
                outcomes.append("\(phase) \(title): \(opened ? "menu" : "NOTHING")")
                if opened {
                    app.typeKey(.escape, modifierFlags: [])
                }
            }
        }
        probe("idle")
        app.buttons["Play Album"].firstMatch.click()
        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "album never started playing")
        probe("playing")

        XCTAssertFalse(
            outcomes.contains { $0.hasSuffix("NOTHING") },
            "right-click raised no menu: \(outcomes.joined(separator: ", "))"
        )
    }

    /// The same check for the song list on an artist's page, reached from the
    /// Artists grid. It never had the fault (the cards take no keyboard focus),
    /// and this keeps it that way.
    func testTrackContextMenuOpensOnAnArtistPageFromTheGrid() {
        self.assertTrackContextMenuOpensOnAnArtistPage(viewMode: "grid")
    }

    /// The list layout opens an artist through a button row, not a card.
    func testTrackContextMenuOpensOnAnArtistPageFromTheList() {
        self.assertTrackContextMenuOpensOnAnArtistPage(viewMode: "list")
    }

    private func assertTrackContextMenuOpensOnAnArtistPage(viewMode: String) {
        // Pinned, because the layout lives in the container's shared defaults
        // and would otherwise be whatever an earlier run left behind.
        let app = self.session.launch(
            arguments: MenuManifest.matrixDefaults + ["-artists.viewMode", viewMode]
        )
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")

        app.activate()
        app.descendants(matching: .any).matching(identifier: "sidebar.artists").firstMatch.click()
        // A grid card is static text; a list row is a button carrying the name.
        let artist = viewMode == "list"
            ? app.buttons["E2E Fixtures"].firstMatch
            : app.staticTexts["E2E Fixtures"].firstMatch
        XCTAssertTrue(artist.waitForExistence(timeout: 8), "never reached Artists (\(viewMode))")
        artist.click()
        XCTAssertTrue(app.firstTrackRow.waitForExistence(timeout: 10), "artist songs never listed")

        var outcomes: [String] = []
        for title in [E2ESession.fixtureTitle, "E2E Tone Two"] {
            app.staticTexts[title].rightClick()
            let opened = app.menuItems["Re-scan File"].waitForExistence(timeout: 3)
            outcomes.append("\(title): \(opened ? "menu" : "NOTHING")")
            if opened {
                app.typeKey(.escape, modifierFlags: [])
            }
        }
        XCTAssertFalse(
            outcomes.contains { $0.hasSuffix("NOTHING") },
            "right-click raised no menu: \(outcomes.joined(separator: ", "))"
        )
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
