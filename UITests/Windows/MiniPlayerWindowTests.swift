import XCTest

// MARK: - MiniPlayerWindowTests

/// Phase 32: the Mini Player window. With a local track playing, toggle the
/// mini player from the main window, cycle every layout (strip, compact,
/// square, visualizer) several times, and assert playback survives each
/// switch and every layout is visited. The chrome controls (layout, pin,
/// dismiss) carry stable identifiers; the transport play/pause inside each
/// layout carries a "Play"/"Pause" accessibility label that doubles as the
/// live play-state probe. Returning via the dismiss button restores the
/// main window with playback intact.
@MainActor
final class MiniPlayerWindowTests: XCTestCase {
    private var session: E2ESession!

    override func setUp() async throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    /// Mini-player chrome identifiers this suite covers (completeness guard).
    static let coveredIdentifiers = ["miniPlayer.layout", "miniPlayer.pin", "miniPlayer.dismiss"]

    /// Every layout the cycle button must visit, mirroring
    /// `MiniPlayerViewModel.Layout`.
    static let expectedLayouts: Set = ["strip", "compact", "square", "visualizer"]

    // MARK: The crawl

    func testMiniPlayerModesSurvivePlayback() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)

        // Arrange: a two-track queue, playing, so playback has something to
        // survive on across every mode switch.
        inv.selectSidebar("Songs")
        app.firstTrackRow.click()
        inv.invoke(["Track", "Select All"])
        inv.waitFor("both tracks selected") { inv.selectedTrackRowCount() == 2 }
        inv.invoke(["Track", "Play Now"])
        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "fixture never started playing")

        // Open the mini player from the main window.
        inv.invoke(["View", "Toggle Miniplayer"])
        XCTAssertTrue(
            app.windows["Mini Player"].waitForExistence(timeout: 8),
            "mini player window never opened"
        )

        // Chrome present.
        for identifier in Self.coveredIdentifiers {
            XCTAssertTrue(
                inv.element(identifier).waitForExistence(timeout: 6),
                "mini player chrome control \(identifier) is missing"
            )
        }

        // Cycle every layout three full times (the spec's ordering-race
        // smoke test), asserting at each stop that the layout is one of the
        // four and that the transport still reports playing.
        var visited: Set<String> = []
        let layoutButton = inv.element("miniPlayer.layout")
        let steps = Self.expectedLayouts.count * 3
        for step in 0 ..< steps {
            let layout = Self.layoutName(from: layoutButton.label)
            XCTAssertTrue(
                Self.expectedLayouts.contains(layout),
                "unexpected mini layout \"\(layout)\" at step \(step)"
            )
            visited.insert(layout)
            // Playback survives into this mode: the mini transport's
            // play/pause reads "Pause". The main window is ordered out while
            // the mini player is up, so the label is unambiguous app-wide.
            XCTAssertTrue(
                app.buttons["Pause"].waitForExistence(timeout: 6),
                "playback did not survive into mini layout \"\(layout)\" (step \(step))"
            )
            layoutButton.click()
            inv.settle(0.5)
        }
        XCTAssertEqual(visited, Self.expectedLayouts, "not every mini layout was visited")

        // Return to the main window; playback and the main transport return.
        inv.element("miniPlayer.dismiss").click()
        // Both conditions in one poll: checking window teardown as a
        // separate, immediate assertion right after the transport-returns
        // wait raced the window's actual removal from the AX tree — the
        // window closes a beat after the main transport reappears, not
        // atomically with it.
        inv.waitFor("main window transport returns and mini player closes") {
            inv.element("nowPlayingStrip.playPause").exists && !app.windows["Mini Player"].exists
        }
        XCTAssertTrue(
            app.waitUntilPlaying(timeout: 10),
            "playback did not survive returning to the main window"
        )
    }

    // MARK: Helpers

    /// The layout name embedded in the cycle button's accessibility label
    /// ("Cycle mini player layout, currently <layout>").
    static func layoutName(from label: String) -> String {
        label.split(separator: " ").last.map(String.init) ?? label
    }

    private func launch() -> XCUIApplication {
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        return app
    }
}
