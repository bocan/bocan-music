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

    static let coveredIdentifiers = ["history.table", "history.emptyState", "history.noResults", "history.source"]

    /// A fresh fixture launch has no plays, so History opens on its empty
    /// state. Playing a fixture past the threshold (the tones are 60 s and a
    /// play records at 50%) adds the row live, with no reload, and the row
    /// offers the song menu. Then the search contracts of ADR-094 slice 2,
    /// in the same launch because a recorded play costs 30 s to make.
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

        // Search on History filters the plays by song, and is its own.
        let field = app.searchFields.firstMatch
        self.type("zzzz", into: field, app: app)
        XCTAssertTrue(
            inv.element("history.noResults").waitForExistence(timeout: 8),
            "a term matching no song must show the no-results state"
        )
        inv.pressEscape()
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Esc clears the History query and the row returns")
        XCTAssertEqual(self.text(of: field), "", "the field is empty after Esc")

        // A library filter set on Songs is not visible on History, and is
        // still there on the way back.
        self.sidebarRow(app, "sidebar.songs").click()
        XCTAssertTrue(app.waitForTrackRows(timeout: 10), "never returned to Songs")
        self.type("Tone Two", into: field, app: app)
        inv.waitFor("Songs narrows to one tone") { inv.visibleFixtureTitleCount() == 1 }

        self.sidebarRow(app, "sidebar.history").click()
        XCTAssertTrue(row.waitForExistence(timeout: 8), "History lists the play regardless of the Songs filter")
        XCTAssertEqual(self.text(of: field), "", "History opens with an empty field")

        app.typeKey("[", modifierFlags: .command)
        inv.waitFor("back on Songs, still filtered") { inv.visibleFixtureTitleCount() == 1 }
        XCTAssertEqual(self.text(of: field), "Tone Two", "the Songs filter came back with the page")

        // The Source filter (slice 3). The fixture has no Last.fm import, so
        // Last.fm alone is empty and All brings the play back.
        self.sidebarRow(app, "sidebar.history").click()
        XCTAssertTrue(inv.element("history.source").waitForExistence(timeout: 8), "the source picker is in the toolbar")
        app.radioButtons["Last.fm"].firstMatch.click()
        XCTAssertTrue(
            inv.element("history.emptyState").waitForExistence(timeout: 8),
            "no imported listens on the fixture, so Last.fm alone is empty"
        )
        app.radioButtons["All"].firstMatch.click()
        XCTAssertTrue(row.waitForExistence(timeout: 8), "All lists the local play again")
    }

    /// Focuses the field with ⌘F, replaces its contents, and types.
    private func type(_ text: String, into field: XCUIElement, app: XCUIApplication) {
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F did not focus search")
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(text)
    }

    /// The field's text, empty for a placeholder.
    private func text(of field: XCUIElement) -> String {
        let value = field.value as? String ?? ""
        return value == "Search" ? "" : value
    }

    // MARK: Helpers

    /// A plain click on the row element. `MenuInvoker.selectSidebar` taps a
    /// coordinate, and that tap does not navigate on macOS 27.
    private func sidebarRow(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
