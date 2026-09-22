import XCTest

// MARK: - HistorySurfaceTests

/// The History destination (ADR-094): empty before any play, one row per
/// play once a song passes the recording threshold, and the song's menu on
/// a right-click. The search behaviour is slice 2 and is tested there.
@MainActor
final class HistorySurfaceTests: XCTestCase {
    private var session: E2ESession!

    override func setUp() async throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    static let coveredIdentifiers = ["history.table", "history.emptyState"]

    /// A fresh fixture launch has no plays, so History opens on its empty
    /// state. Playing a fixture past the threshold (the tones are 60 s and a
    /// play records at 50%) adds the row live, with no reload, and the row
    /// offers the song menu.
    func testHistoryShowsThePlayAndOffersTheSongMenu() {
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        let inv = MenuInvoker(app: app)
        app.activate()

        // No plays yet.
        self.sidebarRow(app, "sidebar.history").click()
        XCTAssertTrue(
            inv.element("history.emptyState").waitForExistence(timeout: 8),
            "a fresh library must open History on its empty state"
        )

        // Play a fixture past the threshold.
        self.sidebarRow(app, "sidebar.songs").click()
        XCTAssertTrue(app.waitForTrackRows(timeout: 10), "never returned to Songs")
        app.firstTrackRow.doubleClick()
        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "playback never started")

        // Back on History, the row arrives on its own once the play records.
        self.sidebarRow(app, "sidebar.history").click()
        let table = inv.element("history.table")
        let row = table.staticTexts[E2ESession.fixtureTitle].firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 50),
            "the play never appeared in History after the threshold"
        )

        // The song menu. "Show in Finder" exists only in the context menu;
        // Play Now is also a menu bar item and is always in the tree.
        row.rightClick()
        XCTAssertTrue(
            app.menuItems["Show in Finder"].waitForExistence(timeout: 3),
            "right-click on a history row raised no song menu"
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: Helpers

    /// A plain click on the row element. `MenuInvoker.selectSidebar` taps a
    /// coordinate, and that tap does not navigate on macOS 27.
    private func sidebarRow(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
