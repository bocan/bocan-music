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
        let window = self.app.windows["BocanMainWindow"]
        XCTAssertTrue(
            window.waitForExistence(timeout: 10),
            "Expected the main window to be visible on launch"
        )
    }
}
