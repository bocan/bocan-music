import XCTest

// MARK: - SettingsPersistenceTests

/// Phase 32: settings persistence and the Appearance controls. In E2E the
/// Settings scene routes its `@AppStorage` through a per-run `UserDefaults`
/// suite (see `E2EEnvironment.settingsDefaults`), so flipping a preference
/// and relaunching the same run proves the value survives a restart without
/// touching real preferences. This is the permanent guard against the
/// `@AppStorage` RawRepresentable propagation-and-persistence trap class.
@MainActor
final class SettingsPersistenceTests: XCTestCase {
    private var session: E2ESession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    /// One boolean toggle per pane that owns one; flipped, then relaunch-
    /// verified. Panes without a boolean control (slider- or action-only:
    /// Sources, Effects, ReplayGain, Advanced) are covered by the pane-open
    /// crawl instead. Appearance's accent is persistence-checked separately
    /// below because it is a selection, not a toggle.
    static let toggles: [(pane: String, id: String)] = [
        ("general", "settings.general.dockBadge"),
        ("library", "settings.library.quickScan"),
        ("smartPlaylists", "settings.smartPlaylists.liveUpdate"),
        ("podcasts", "settings.podcasts.refreshOnLaunch"),
        ("playback", "settings.playback.crossAlbumGapless"),
        ("lyrics", "settings.lyrics.autoShowPane"),
        ("visualizer", "settings.visualizer.simplifyOnBattery"),
        ("diagnostics", "settings.diagnostics.captureLogs"),
    ]

    // MARK: Persistence

    func testSettingsPersistAcrossRelaunch() {
        // Launch 1: flip every toggle and pick a non-default accent, recording
        // the intended post-flip state.
        let app1 = self.launch()
        let inv1 = MenuInvoker(app: app1)
        let anchor1 = SettingsCrawlTests.openSettings(app1, inv1)
        let expected = self.flipEveryToggleAndAccent(inv1, app1, anchor1)
        app1.terminate()

        // Launch 2: same run id reuses the same suite; every flip persists.
        let app2 = self.launch()
        let inv2 = MenuInvoker(app: app2)
        var anchor2 = SettingsCrawlTests.openSettings(app2, inv2)

        for toggle in Self.toggles {
            anchor2 = SettingsCrawlTests.navigate(inv2, app2, to: toggle.pane, anchor: anchor2)
            let element = inv2.element(toggle.id)
            XCTAssertTrue(element.waitForExistence(timeout: 6), "\(toggle.id) missing after relaunch")
            inv2.waitFor("\(toggle.id) persisted") { Self.boolValue(element) == expected[toggle.id] }
        }

        // Appearance is visited last here too, deliberately out of sidebar
        // order: this is a fresh scroll position after relaunch, so it is
        // its own bidirectional-scroll proof, not just a forward crawl.
        SettingsCrawlTests.navigate(inv2, app2, to: "appearance", anchor: anchor2)
        let green2 = inv2.element("settings.appearance.accent.green")
        XCTAssertTrue(green2.waitForExistence(timeout: 6), "green accent swatch missing after relaunch")
        inv2.waitFor("green accent persisted") { green2.isSelected }
    }

    /// Flips every toggle in `Self.toggles` (sidebar order, so the crawl
    /// never needs to scroll backward) then, last, picks a non-default
    /// accent — deliberately jumping back up to Appearance so
    /// `selectSidebarRow`'s scroll-until-hittable path is proven in both
    /// directions, not just forward. Returns each toggle's resulting value,
    /// for the relaunch assertion.
    private func flipEveryToggleAndAccent(
        _ inv: MenuInvoker,
        _ app: XCUIApplication,
        _ initialAnchor: XCUIElement
    ) -> [String: String] {
        var expected: [String: String] = [:]
        var anchor = initialAnchor
        for toggle in Self.toggles {
            anchor = SettingsCrawlTests.navigate(inv, app, to: toggle.pane, anchor: anchor)
            let element = inv.element(toggle.id)
            XCTAssertTrue(element.waitForExistence(timeout: 6), "\(toggle.id) is missing")
            let before = Self.boolValue(element)
            SettingsCrawlTests.tap(element)
            inv.waitFor("\(toggle.id) flips") { Self.boolValue(element) != before }
            expected[toggle.id] = Self.boolValue(element)
        }

        SettingsCrawlTests.navigate(inv, app, to: "appearance", anchor: anchor)
        let green = inv.element("settings.appearance.accent.green")
        XCTAssertTrue(green.waitForExistence(timeout: 6), "green accent swatch missing")
        SettingsCrawlTests.tap(green)
        inv.waitFor("green accent selected") { green.isSelected }
        return expected
    }

    // MARK: Appearance cycling

    /// Cycle every accent swatch and each appearance mode, asserting the
    /// selection takes and the Settings window stays responsive after each
    /// (the guard that would have caught a renderScale-class regression at
    /// the window level). No pixel assertions: rendering is the snapshot
    /// tier's job.
    func testAppearanceControlsCycle() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        let anchor = SettingsCrawlTests.openSettings(app, inv)
        SettingsCrawlTests.navigate(inv, app, to: "appearance", anchor: anchor)

        let accents = [
            "system", "blue", "purple", "pink", "red",
            "orange", "yellow", "green", "teal", "willowisp",
        ]
        for id in accents {
            let swatch = inv.element("settings.appearance.accent.\(id)")
            XCTAssertTrue(swatch.waitForExistence(timeout: 6), "accent swatch \(id) missing")
            SettingsCrawlTests.tap(swatch)
            inv.waitFor("accent \(id) selects") { swatch.isSelected }
            XCTAssertTrue(
                inv.element("settings.sidebar.general").exists,
                "Settings window unresponsive after accent \(id)"
            )
        }

        // The Theme picker is a segmented control; its segments surface as
        // radio buttons (which disambiguates the "System" segment from the
        // "System" accent swatch, a plain button). Cycle each and confirm the
        // window survives.
        for scheme in ["Light", "Dark", "System"] {
            let option = app.radioButtons[scheme]
            XCTAssertTrue(option.waitForExistence(timeout: 6), "appearance option \(scheme) missing")
            option.click()
            inv.settle(0.4)
            XCTAssertTrue(
                inv.element("settings.sidebar.general").exists,
                "Settings window unresponsive after appearance \(scheme)"
            )
        }
    }

    // MARK: Helpers

    /// A toggle's on/off state as a stable string. SwiftUI toggles surface
    /// their value as a 0/1 number, which `as? String` misses, so describe
    /// the raw value instead.
    static func boolValue(_ element: XCUIElement) -> String {
        String(describing: element.value ?? "")
    }

    private func launch() -> XCUIApplication {
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        return app
    }
}
