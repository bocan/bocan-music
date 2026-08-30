import XCTest

// MARK: - PlaylistSurfaceTests

/// Phase 31 surface crawl: the smart-playlist detail. Opened via a seeded
/// smart playlist that matches the fixtures ("Never Played" — the two
/// tones have never been played). The identified *control* is Edit Rules;
/// `view`/`header` are layout-container identifiers (an HStack/VStack),
/// which SwiftUI does not expose as queryable elements, so they are not
/// crawled. Refresh appears only on non-live smart playlists (the seeded
/// ones are live), so it is out of reach here too.
@MainActor
final class PlaylistSurfaceTests: XCTestCase {
    private var session: E2ESession!

    override func setUp() async throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    static let smartPlaylistCoveredIdentifiers = ["smartPlaylist.detail.edit"]

    func testSmartPlaylistDetailSurface() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        // "Never Played" is a seeded smart playlist; the fixtures match it.
        inv.selectSidebar("Never Played")

        // The Edit Rules button is addressed by label: its
        // `smartPlaylist.detail.edit` identifier does not reach the AX tree
        // (the enclosing header HStack's own `.accessibilityIdentifier`
        // masks the child button's id — a minor phase-29-style gap; the
        // control is still reachable by its label).
        let edit = app.buttons["Edit Rules"]
        XCTAssertTrue(edit.waitForExistence(timeout: 8), "smart playlist detail never opened")
        edit.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5), "Edit Rules did not open the rule editor")
        inv.dismissSheet()
        inv.waitFor("rule editor dismissed") { !app.sheets.firstMatch.exists }
    }

    private func launch() -> XCUIApplication {
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        return app
    }
}
