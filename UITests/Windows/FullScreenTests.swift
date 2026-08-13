import XCTest

// MARK: - FullScreenTests

/// Phase 32: full-screen enter/exit on the main window, and the permanent
/// regression guard that Escape exits full screen (step 5 of the #378
/// precedence ladder). The app installs Escape monitors for navigation
/// drill-out; this proves they do not swallow the Escape that AppKit uses
/// to leave full screen.
///
/// Full-screen state is read from the View menu, which flips its item
/// between "Enter Full Screen" and "Exit Full Screen". `menuHasItem` opens
/// and closes the menu with its own Escape, which the open menu consumes,
/// so it never races the window's full-screen Escape.
///
/// The app is held as a property and `tearDownWithError` force-exits full
/// screen even if an assertion fails mid-test: a force-terminated full-screen
/// window leaves an orphaned Space that can wedge the WindowServer for the
/// rest of the run, so leaving full screen is a hard invariant of this suite.
@MainActor
final class FullScreenTests: XCTestCase {
    private var session: E2ESession!
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    override func tearDownWithError() throws {
        // Guarantee the app is windowed before it is torn down, whatever the
        // test outcome, so a wedged full-screen Space can never survive.
        guard let app = self.app else { return }
        let inv = MenuInvoker(app: app)
        if inv.menuHasItem("View", "Exit Full Screen") {
            app.typeKey(.escape, modifierFlags: [])
            _ = inv.waitFor("teardown exits full screen", timeout: 12) {
                inv.menuHasItem("View", "Enter Full Screen")
            }
        }
        self.app = nil
    }

    func testEscapeExitsFullScreen() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)

        // Start windowed.
        XCTAssertTrue(
            inv.menuHasItem("View", "Enter Full Screen"),
            "the app should start windowed, showing Enter Full Screen"
        )

        // Enter full screen from the system View menu item.
        inv.invoke(["View", "Enter Full Screen"])
        inv.waitFor("entered full screen", timeout: 12) {
            inv.menuHasItem("View", "Exit Full Screen")
        }

        // Escape leaves full screen: the navigation Escape monitors must not
        // consume it before AppKit does.
        app.typeKey(.escape, modifierFlags: [])
        inv.waitFor("Escape exits full screen", timeout: 12) {
            inv.menuHasItem("View", "Enter Full Screen")
        }
    }

    private func launch() -> XCUIApplication {
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        self.app = app
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        return app
    }
}
