import XCTest

// MARK: - SearchSurfaceTests

/// Phase 31 surface: the toolbar search (the `.searchable` field, which
/// SwiftUI owns without an app identifier). This is an interaction test,
/// not an identifier crawl: type-to-search from the browse view filters
/// the local track table (no network), and clearing restores it.
@MainActor
final class SearchSurfaceTests: XCTestCase {
    private var session: E2ESession!

    override func setUp() async throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    func testSearchFiltersTheTrackTable() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        inv.selectSidebar("Songs")
        inv.waitFor("both fixtures visible") { inv.visibleFixtureTitleCount() == 2 }

        // Focus the search field (⌘F) and narrow to a single tone.
        app.typeKey("f", modifierFlags: .command)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F did not focus search")
        field.click()
        app.typeText("Tone Two")
        inv.waitFor("search narrows to one tone") { inv.visibleFixtureTitleCount() == 1 }
        XCTAssertTrue(app.staticTexts["E2E Tone Two"].exists, "the matching tone must remain")

        // Clear restores the full list.
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        inv.pressEscape()
        inv.selectSidebar("Songs")
        inv.waitFor("full list restored") { inv.visibleFixtureTitleCount() == 2 }
    }

    private func launch() -> XCUIApplication {
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        return app
    }
}
