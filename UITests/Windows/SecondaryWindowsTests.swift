import XCTest

// MARK: - SecondaryWindowsTests

/// Phase 32: the app's secondary windows opened from the menu bar. Each is
/// opened, its identified controls exercised with concrete postconditions,
/// and closed. Covers the Library Summary tab strip, the Log Console
/// control bar, and the Equaliser & DSP tabbed panel.
@MainActor
final class SecondaryWindowsTests: XCTestCase {
    private var session: E2ESession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    /// Identifiers this suite covers (completeness guard). Library Summary
    /// tabs are enumerated from the six-section strip.
    static let librarySummaryTabs = [
        "basicInfo", "libraryHygiene", "audioQuality",
        "collectionShape", "listeningBehaviour", "podcasts",
    ]
    static let logConsoleCovered = [
        "logConsole.level", "logConsole.categories", "logConsole.search",
        "logConsole.pause", "logConsole.clear", "logConsole.copy",
        "logConsole.export", "logConsole.tail",
    ]
    static let dspCovered = [
        "dsp.eq.enable", "dsp.eq.preset", "dsp.eq.scope", "dsp.eq.outputGain",
    ]

    // MARK: Library Summary

    /// Tools ▸ Library Summary (⇧⌘Y): every tab in the six-section strip
    /// selects its pane, then the window closes.
    func testLibrarySummaryTabs() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)

        inv.invoke(["Tools", "Library Summary…"])
        XCTAssertTrue(
            app.windows["Library Summary"].waitForExistence(timeout: 8),
            "Library Summary window never opened"
        )

        for raw in Self.librarySummaryTabs {
            let tab = inv.element("librarySummary.tab.\(raw)")
            XCTAssertTrue(tab.waitForExistence(timeout: 6), "Library Summary tab \(raw) is missing")
            tab.click()
            inv.waitFor("Library Summary tab \(raw) selects") { tab.isSelected }
        }

        inv.closeFrontWindow()
        XCTAssertTrue(
            inv.waitFor("Library Summary window closes") { !app.windows["Library Summary"].exists }
        )
    }

    // MARK: Log Console

    /// Help ▸ Log Console (⇧⌘L): the control bar's pickers open menus, the
    /// search field filters, the pause and tail toggles flip, then close.
    func testLogConsoleControls() {
        let app = self.launch()
        let crawler = SurfaceCrawler(app: app)
        let inv = crawler.inv

        inv.invoke(["Help", "Log Console"])
        XCTAssertTrue(
            app.windows["Log Console"].waitForExistence(timeout: 8),
            "Log Console window never opened"
        )

        crawler.crawl("Log Console", [
            Self.menuOpener("logConsole.level", "Level picker"),
            Self.menuOpener("logConsole.categories", "Categories menu"),
            Self.flipLabel("logConsole.pause", "Pause / Resume"),
            Self.menuOpener("logConsole.clear", "Clear menu"),
            // Copy writes the visible lines to the pasteboard; the runner
            // sandbox cannot observe the pasteboard, so the postcondition is
            // the spec's remains-present-and-responsive fallback.
            SurfaceControl("logConsole.copy", "Copy to clipboard") { _, inv, _ in
                inv.element("logConsole.copy").isEnabled
            },
            // Export opens an NSSavePanel (a modal system sheet); asserted
            // present, not clicked, to avoid a blocking save dialog.
            SurfaceControl(
                "logConsole.export", "Export log", action: .presence,
                skip: "opens a modal NSSavePanel the crawl must not block on"
            ) { _, inv, _ in inv.element("logConsole.export").isEnabled },
            Self.flipValue("logConsole.tail", "Tail toggle"),
        ])

        // The search field filters live; type-to-filter, then clear.
        let search = inv.element("logConsole.search")
        XCTAssertTrue(search.waitForExistence(timeout: 6), "log console search field missing")
        search.click()
        search.typeText("audio")
        inv.waitFor("search field accepts text") {
            ((search.value as? String) ?? "").contains("audio")
        }
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        inv.waitFor("search field clears") {
            !((search.value as? String) ?? "").contains("audio")
        }

        inv.closeFrontWindow()
        XCTAssertTrue(
            inv.waitFor("Log Console window closes") { !app.windows["Log Console"].exists }
        )
    }

    // MARK: Equaliser & DSP

    /// View ▸ Equaliser & DSP (⌥⌘E): the EQ enable toggle flips, the preset
    /// menu opens, and each of the three tabs (Equaliser, Effects,
    /// ReplayGain) reveals a representative control, then close.
    func testDSPWindow() {
        let app = self.launch()
        let crawler = SurfaceCrawler(app: app)
        let inv = crawler.inv

        inv.invoke(["View", "Equaliser & DSP…"])
        XCTAssertTrue(
            app.windows["Equaliser & DSP"].waitForExistence(timeout: 8),
            "Equaliser & DSP window never opened"
        )

        crawler.crawl("DSP", [
            Self.flipValue("dsp.eq.enable", "EQ enable toggle"),
            Self.menuOpener("dsp.eq.preset", "EQ preset menu"),
            // The scope segmented control and output-gain slider are
            // continuous/segmented; asserted present with the panel responsive.
            SurfaceControl(
                "dsp.eq.scope", "EQ scope picker", action: .presence,
                skip: "segmented control; scope switching side effects need seeded EQ state"
            ) { _, inv, _ in inv.element("dsp.eq.enable").exists },
            SurfaceControl(
                "dsp.eq.outputGain", "EQ output gain", action: .presence,
                skip: "continuous slider; gain changes race the live signal"
            ) { _, inv, _ in inv.element("dsp.eq.enable").exists },
        ])

        // Walk the three tabs, each revealing a control it uniquely owns.
        self.switchTab(app, inv, "Effects")
        inv.waitFor("Effects tab shows the bass-boost slider") {
            inv.element("settings.effects.bassBoost").exists
        }
        self.switchTab(app, inv, "ReplayGain")
        inv.waitFor("ReplayGain tab shows the preamp slider") {
            inv.element("settings.replayGain.preamp").exists
        }
        self.switchTab(app, inv, "Equaliser")
        inv.waitFor("back on the Equaliser tab") { inv.element("dsp.eq.enable").exists }

        inv.closeFrontWindow()
        XCTAssertTrue(
            inv.waitFor("DSP window closes") { !app.windows["Equaliser & DSP"].exists }
        )
    }

    // MARK: Table helpers

    /// A pop-up/menu control whose click opens a menu; Escape closes it.
    private static func menuOpener(_ identifier: String, _ name: String) -> SurfaceControl {
        SurfaceControl(
            identifier, name,
            restore: { _, inv in inv.pressEscape() }
        ) { app, _, _ in app.menus.firstMatch.exists }
    }

    /// A button whose accessibility label flips on click (Pause/Resume).
    private static func flipLabel(_ identifier: String, _ name: String) -> SurfaceControl {
        SurfaceControl(
            identifier, name,
            restore: { _, inv in inv.element(identifier).click()
                inv.settle(0.3)
            }
        ) { _, inv, context in
            inv.element(identifier).label != context.priorLabel
        }
    }

    /// A toggle whose accessibility value flips on click. Native SwiftUI
    /// `Toggle`s bridge their AX value as an NSNumber, not a String, so
    /// `String(describing:)` is used rather than `as? String` (see
    /// `SurfaceCrawler`'s matching `ControlContext` capture).
    private static func flipValue(_ identifier: String, _ name: String) -> SurfaceControl {
        SurfaceControl(
            identifier, name,
            restore: { _, inv in inv.element(identifier).click()
                inv.settle(0.3)
            }
        ) { _, inv, context in
            String(describing: inv.element(identifier).value ?? "") != context.priorValue
        }
    }

    // MARK: Helpers

    /// Clicks a macOS `TabView` tab by its title. Tab items surface as radio
    /// buttons in the tab bar; fall back to any element carrying the label.
    private func switchTab(_ app: XCUIApplication, _ inv: MenuInvoker, _ title: String) {
        if app.radioButtons[title].exists {
            app.radioButtons[title].click()
        } else {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", title)).firstMatch.click()
        }
        inv.settle(0.3)
    }

    private func launch() -> XCUIApplication {
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        return app
    }
}
