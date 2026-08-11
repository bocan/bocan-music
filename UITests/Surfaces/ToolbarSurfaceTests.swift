import XCTest

// MARK: - ToolbarSurfaceTests

/// Phase 31 surface crawl: the main-window toolbar. Every identified
/// toolbar control is clicked with a concrete postcondition (navigation
/// changes, pane toggles flip their label, the mini player appears), plus
/// a tooltip spot-check. The `controls` table is the reviewable artifact;
/// `SurfaceCrawler` interprets it.
///
/// Negative-test drill (verified manually 2026-08-11): renaming
/// `toolbar.lyrics` in the table to a non-existent identifier failed the
/// crawl with "control toolbar.lyricsX (Lyrics pane toggle) is missing".
@MainActor
final class ToolbarSurfaceTests: XCTestCase {
    private var session: E2ESession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    /// Toolbar identifiers this suite covers, for the phase 31 completeness
    /// test (every registered surface identifier lives in exactly one table).
    static let coveredIdentifiers = [
        "toolbar.back", "toolbar.forward", "toolbar.lyrics",
        "toolbar.visualizer", "toolbar.miniPlayer", "toolbar.identifyTrack",
    ]

    // MARK: The crawl

    func testToolbarSurface() {
        let app = self.launch()
        let crawler = SurfaceCrawler(app: app)

        // Arrange: navigate so Back/Forward are live (destination history).
        crawler.inv.selectSidebar("Albums")
        crawler.inv.waitFor("on Albums") { app.windows.firstMatch.title == "Albums" }

        crawler.crawl("Toolbar", Self.controls)
    }

    static var controls: [SurfaceControl] {
        [
            // History is [Songs -> Albums]; Back returns to Songs, then
            // Forward returns to Albums.
            SurfaceControl("toolbar.back", "Back navigation") { app, _, _ in
                app.windows.firstMatch.title == "Songs"
            },
            SurfaceControl("toolbar.forward", "Forward navigation") { app, _, _ in
                app.windows.firstMatch.title == "Albums"
            },
            SurfaceControl(
                "toolbar.lyrics", "Lyrics pane toggle",
                restore: { _, inv in inv.element("toolbar.lyrics").click()
                    inv.settle(0.3)
                }
            ) { _, inv, context in
                inv.element("toolbar.lyrics").label != context.priorLabel
            },
            SurfaceControl(
                "toolbar.visualizer", "Visualizer pane toggle",
                restore: { _, inv in inv.element("toolbar.visualizer").click()
                    inv.settle(0.3)
                }
            ) { _, inv, context in
                inv.element("toolbar.visualizer").label != context.priorLabel
            },
            // Toggling the mini player swaps the main window for the compact
            // one; restore with the global shortcut (the main toolbar is gone
            // while the mini player is up).
            SurfaceControl(
                "toolbar.miniPlayer", "Mini player toggle",
                restore: { app, inv in
                    app.typeKey("m", modifierFlags: [.command, .option])
                    inv.settle(0.6)
                }
            ) { _, inv, _ in
                inv.element("miniPlayer.layout").waitForExistence(timeout: 5)
            },
            // Networked (AcoustID): asserted present and correctly disabled
            // without a single-track selection, not clicked (phase 34).
            SurfaceControl(
                "toolbar.identifyTrack", "Identify Track",
                action: .presence,
                skip: "opens a live AcoustID lookup (network); hermetic network is phase 34"
            ) { _, inv, _ in
                !inv.element("toolbar.identifyTrack").isEnabled
            },
        ]
    }

    // MARK: Tooltip spot-check (quarantinable)

    /// Hovers a few toolbar controls and asserts a real tooltip renders with
    /// the control's help text. macOS shows tooltips in an app-owned window
    /// after a system delay, so this is timing-sensitive.
    ///
    /// Quarantined: on this OS (macOS 26) an XCUITest `.hover()` does not
    /// make the window server render an *observable* tooltip window (the
    /// pointer-dwell the OS requires is not reproduced, and the tooltip's
    /// text is not exposed to the accessibility tree either). The
    /// *existence* of `.help()` on every control is already guaranteed by
    /// phase 29's `audit-help-text.py`, so this render spot-check is a
    /// bonus, not the guarantee. Flip `Self.tooltipsObservable` to re-enable
    /// if a future OS/XCUITest surfaces tooltip windows.
    static let tooltipsObservable = false

    func testToolbarTooltips() throws {
        try XCTSkipUnless(
            Self.tooltipsObservable,
            "macOS tooltip windows are not observable via XCUITest hover on this OS; help-text existence is guaranteed by phase 29's audit"
        )
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        // Hovering a control the mouse already rests on shows no tooltip, so
        // move away first, then to each target.
        for (identifier, help) in [
            ("toolbar.lyrics", "Toggle lyrics pane"),
            ("toolbar.visualizer", "Toggle visualizer pane"),
            ("toolbar.identifyTrack", "Identify track using AcoustID"),
        ] {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            inv.settle(0.5)
            // Dwell on the control: macOS only shows a tooltip once the
            // pointer settles, so re-hover and wait without moving.
            inv.element(identifier).hover()
            let appeared = inv.waitFor("tooltip for \(identifier)", timeout: 5) {
                app.descendants(matching: .any).matching(
                    NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", help, help)
                ).firstMatch.exists
            }
            XCTAssertTrue(appeared, "no tooltip containing \"\(help)\" for \(identifier)")
        }
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
