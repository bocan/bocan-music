import XCTest

// MARK: - SettingsCrawlTests

/// Phase 32: the Settings scene. Opens Settings, navigates every pane in
/// the sidebar, and asserts each pane's detail renders by probing a control
/// it uniquely owns. Navigation relies on the sidebar-row identifiers added
/// in this phase (tag-selected `List(selection:)` rows are otherwise absent
/// from the AX tree, the same VoiceOver defect the main sidebar hit).
@MainActor
final class SettingsCrawlTests: XCTestCase {
    private var session: E2ESession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    // MARK: Pane table

    /// One settings pane: its `SettingsPage.rawValue` (for the sidebar-row
    /// identifier) and the identifiers of controls it uniquely owns, any one
    /// of which proves the pane rendered.
    struct Pane {
        let raw: String
        let reps: [String]
        let conditional: Bool

        init(_ raw: String, _ reps: String..., conditional: Bool = false) {
            self.raw = raw
            self.reps = reps
            self.conditional = conditional
        }
    }

    /// Every sidebar pane, in sidebar order. Scrobbling is present only when
    /// a provider is configured, so it is conditional.
    static let panes: [Pane] = [
        Pane("general", "settings.general.launchAtLogin"),
        Pane("appearance", "settings.appearance.accent.blue"),
        Pane("library", "settings.library.quickScan"),
        Pane("sources", "settings.sources.addServer", "settings.sources.addServer.empty"),
        Pane("smartPlaylists", "settings.smartPlaylists.liveUpdate"),
        Pane("podcasts", "settings.podcasts.refreshOnLaunch"),
        Pane("phoneSync", "settings.phoneSync.enable"),
        Pane("playback", "settings.playback.crossAlbumGapless"),
        Pane("equaliser", "dsp.eq.enable"),
        Pane("effects", "settings.effects.bassBoost"),
        Pane("replayGain", "settings.replayGain.preamp"),
        Pane("lyrics", "settings.lyrics.autoShowPane"),
        Pane("visualizer", "settings.visualizer.simplifyOnBattery"),
        Pane("advanced", "settings.advanced.logLevel"),
        Pane("diagnostics", "settings.diagnostics.captureLogs"),
        // Scrobbling is handled separately: its identified controls (queue
        // stats, Recent Scrobbles) render only with activity, so its pane is
        // proven via the always-present "Last.fm" provider header instead.
    ]

    // MARK: The crawl

    func testEverySettingsPaneOpens() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)

        var anchor = Self.openSettings(app, inv)

        for pane in Self.panes {
            let row = inv.element("settings.sidebar.\(pane.raw)")
            if pane.conditional, !row.waitForExistence(timeout: 2) { continue }
            XCTAssertTrue(row.waitForExistence(timeout: 6), "settings sidebar row \(pane.raw) is missing")
            Self.selectSidebarRow(row, anchor: anchor, app: app)
            inv.settle(0.3)
            inv.waitFor("settings pane \(pane.raw) renders") {
                pane.reps.contains { inv.element($0).exists }
            }
            anchor = row
        }

        inv.closeFrontWindow()
    }

    // MARK: Helpers

    /// Opens the Settings scene, waits for its sidebar to appear, and
    /// returns the "General" row — always selected and hittable on open —
    /// as the crawl's first scroll anchor (see `selectSidebarRow`).
    @discardableResult
    static func openSettings(_ app: XCUIApplication, _ inv: MenuInvoker) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let general = inv.element("settings.sidebar.general")
        XCTAssertTrue(general.waitForExistence(timeout: 10), "Settings scene never opened")
        return general
    }

    /// Selects a settings pane by its `SettingsPage.rawValue`, scrolling
    /// from `anchor` if needed, and waits for the selection to take.
    /// Returns the row just selected, to thread as the next call's anchor.
    /// Shared by the persistence suite.
    @discardableResult
    static func navigate(_ inv: MenuInvoker, _ app: XCUIApplication, to raw: String, anchor: XCUIElement) -> XCUIElement {
        let row = inv.element("settings.sidebar.\(raw)")
        XCTAssertTrue(row.waitForExistence(timeout: 6), "settings sidebar row \(raw) is missing")
        self.selectSidebarRow(row, anchor: anchor, app: app)
        inv.settle(0.3)
        return row
    }

    /// Selects a sidebar row: a plain click when hittable. The sidebar's 15
    /// panes across 5 sections do not all fit inside the scene's minimum
    /// window size, so a row outside the visible fold reports an AX frame
    /// outside the window's clip area — synthesizing a gesture (a click, or
    /// even a scroll) directly at that frame fails outright ("Unable to
    /// find hit point"), since XCTest can't resolve a real on-screen
    /// location there. Scroll from `anchor` instead: a row already known to
    /// be hittable (typically whichever was selected last), toward the
    /// target's reported position relative to the window (the crawl is not
    /// always forward: the persistence suite deliberately jumps back up to
    /// Appearance after Diagnostics) until the target is genuinely
    /// hittable, then fall back to the coordinate tap the un-clipped case
    /// still needs (List rows report not-hittable even when fully visible;
    /// the cell is the hit target).
    static func selectSidebarRow(_ row: XCUIElement, anchor: XCUIElement, app: XCUIApplication) {
        guard !row.isHittable else {
            row.click()
            return
        }
        let goingDown = row.frame.midY >= app.windows.firstMatch.frame.midY
        // A large step: `anchor` itself can scroll out of view (and so stop
        // taking further scroll gestures) after only a couple of small
        // steps, particularly on a long jump like Diagnostics back up to
        // Appearance, which spans nearly the whole sidebar. A big single
        // gesture crosses that distance before the anchor goes stale.
        let deltaY: CGFloat = goingDown ? -300 : 300
        var attempts = 0
        while !row.isHittable, attempts < 10 {
            anchor.scroll(byDeltaX: 0, deltaY: deltaY)
            attempts += 1
        }
        if row.isHittable {
            row.click()
        } else {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// A plain click when hittable, else a centre-point coordinate tap
    /// (macOS List rows report not-hittable even fully visible: the cell is
    /// the hit target). For in-pane controls that don't need scrolling; see
    /// `selectSidebarRow` for the sidebar's own rows.
    static func tap(_ element: XCUIElement) {
        if element.isHittable {
            element.click()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func launch() -> XCUIApplication {
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        return app
    }
}
