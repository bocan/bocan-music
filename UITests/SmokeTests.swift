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

    /// Verifies the main window contains the placeholder "Hello, Bòcan" text.
    func testHelloWorld() {
        let label = self.app.staticTexts["Hello, Bòcan"]
        XCTAssertTrue(
            label.waitForExistence(timeout: 5),
            "Expected 'Hello, Bòcan' label to be visible on launch"
        )
    }
}
