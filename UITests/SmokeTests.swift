import XCTest

final class SmokeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.app = XCUIApplication()
        self.app.launch()
    }

    override func tearDownWithError() throws {
        self.app.terminate()
    }

    /// Verifies the main window is visible on launch.
    func testMainWindowVisible() {
        // app.windows["title"] matches by NSWindow title, not by a SwiftUI
        // .accessibilityIdentifier() on a view inside the window.  Use
        // firstMatch instead — if any window appears within the timeout the
        // app has launched successfully.
        let window = self.app.windows.firstMatch
        XCTAssertTrue(
            window.waitForExistence(timeout: 10),
            "Expected at least one window to be visible on launch"
        )
    }
}
