import XCTest

// MARK: - VisualizerLivenessTests

/// Phase 33: during real playback, cycle every visualizer mode in every
/// palette and assert liveness — the `FrameRateMonitor`'s rolling FPS,
/// exposed as an accessibility value only under the E2E flag (see
/// `VisualizerViewModel.e2eLiveness`) — in the main pane, the mini player,
/// and full screen. No pixel or perceptual assertions: this suite proves
/// frames are actually being drawn, not what they look like.
@MainActor
final class VisualizerLivenessTests: XCTestCase {
    private var session: E2ESession!

    override func setUp() async throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    /// Safety bound for mode/palette cycling loops. Not a correctness
    /// dependency: cycling stops as soon as a value repeats, however many
    /// are actually available (Nebula drops out without a Metal device or
    /// with Reduce Motion on).
    private static let maxCycleSteps = 7

    // MARK: Main pane: every mode x every palette

    /// The full cross matrix, discovered rather than hardcoded: cycles the
    /// mode stepper, and at each mode cycles the palette stepper through a
    /// full loop, asserting liveness at every combination.
    func testMainPaneModeAndPaletteMatrix() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        self.startPlaybackAndOpenPane(app, inv)
        let hoverTarget = inv.element("visualizerPane")

        var visitedModes: Set<String> = []
        for _ in 0 ..< Self.maxCycleSteps {
            guard let mode = self.readValue(inv, identifier: "visualizer.overlay.mode.value") else {
                XCTFail("could not read mode value")
                return
            }
            if visitedModes.contains(mode) { break }
            visitedModes.insert(mode)

            var visitedPalettes: Set<String> = []
            for _ in 0 ..< Self.maxCycleSteps {
                guard let palette = self.readValue(inv, identifier: "visualizer.overlay.palette.value") else {
                    XCTFail("could not read palette value")
                    return
                }
                if visitedPalettes.contains(palette) { break }
                visitedPalettes.insert(palette)

                self.assertLiveness(inv, context: "main pane \(mode) / \(palette)")
                self.stepStepperNext(inv, hoverTarget: hoverTarget, rowIdentifier: "visualizer.overlay.palette")
            }
            self.stepStepperNext(inv, hoverTarget: hoverTarget, rowIdentifier: "visualizer.overlay.mode")
        }
        XCTAssertFalse(visitedModes.isEmpty, "no visualizer modes were visited")
    }

    // MARK: Mini player: reduced matrix (each mode once, default palette)

    func testMiniPlayerModeMatrix() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        self.startPlayback(app, inv)
        self.openMiniPlayerInVisualizerLayout(app, inv)
        let hoverTarget = app.windows["Mini Player"]

        var visitedModes: Set<String> = []
        for _ in 0 ..< Self.maxCycleSteps {
            guard let mode = self.readValue(inv, identifier: "visualizer.overlay.mode.value") else {
                XCTFail("could not read mode value (mini player)")
                return
            }
            if visitedModes.contains(mode) { break }
            visitedModes.insert(mode)
            self.assertLiveness(inv, context: "mini player \(mode)")
            self.stepStepperNext(inv, hoverTarget: hoverTarget, rowIdentifier: "visualizer.overlay.mode")
        }
        XCTAssertFalse(visitedModes.isEmpty, "no visualizer modes were visited in the mini player")
    }

    // MARK: Full screen: reduced matrix (each mode once, default palette)

    func testFullScreenModeMatrix() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        // Deliberately does not open the main pane first: A11y.Visualizer.host
        // is shared by design across all three surfaces (see
        // LivenessAccessibilityValue's doc comment), so a live main pane
        // alongside the fullscreen window would leave two elements carrying
        // the same identifier and make `inv.element(...)` queries ambiguous.
        self.startPlayback(app, inv)
        self.openFullScreenVisualizer(app, inv)
        let hoverTarget = app.windows["Visualizer"]

        var visitedModes: Set<String> = []
        for _ in 0 ..< Self.maxCycleSteps {
            guard let mode = self.readValue(inv, identifier: "visualizer.overlay.mode.value") else {
                XCTFail("could not read mode value (full screen)")
                return
            }
            if visitedModes.contains(mode) { break }
            visitedModes.insert(mode)
            self.assertLiveness(inv, context: "full screen \(mode)")
            self.stepStepperNext(inv, hoverTarget: hoverTarget, rowIdentifier: "visualizer.overlay.mode")
        }
        XCTAssertFalse(visitedModes.isEmpty, "no visualizer modes were visited in full screen")

        inv.closeFrontWindow()
    }

    // MARK: Rapid-cycle torture test

    /// Cycles every mode as fast as the UI allows, twice through, then
    /// asserts liveness and that playback never stopped. Mode-switch
    /// teardown races (the Metal renderer tearing down/rebuilding via the
    /// host's `rendererKey`) are historically where visualizer crashes live.
    func testRapidModeCyclingSurvivesPlayback() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        self.startPlaybackAndOpenPane(app, inv)
        let hoverTarget = inv.element("visualizerPane")

        for _ in 0 ..< (Self.maxCycleSteps * 2) {
            self.stepStepperNext(inv, hoverTarget: hoverTarget, rowIdentifier: "visualizer.overlay.mode")
            inv.settle(0.1)
        }

        XCTAssertTrue(app.waitUntilPlaying(timeout: 5), "playback stopped during rapid mode cycling")
        self.assertLiveness(inv, context: "after rapid cycling")
    }

    // MARK: Appearance interaction

    /// With a Metal mode live, switches light/dark appearance and two
    /// accents; asserts liveness after each (phase 32 owns the full accent
    /// cycle and appearance-persistence proof — this only checks the
    /// visualizer survives the Metal-layer invalidation each switch causes).
    func testAppearanceSwitchWhileMetalModeLive() {
        let app = self.launch()
        let inv = MenuInvoker(app: app)
        self.startPlaybackAndOpenPane(app, inv)
        let hoverTarget = inv.element("visualizerPane")

        // Cycle to a Metal-only mode (Nebula) if available, so the
        // appearance switch exercises the stricter Metal path; any mode
        // still proves liveness if Nebula isn't available on this machine.
        var seen: Set<String> = []
        for _ in 0 ..< Self.maxCycleSteps {
            guard let mode = self.readValue(inv, identifier: "visualizer.overlay.mode.value") else { break }
            if mode == "Nebula" || seen.contains(mode) { break }
            seen.insert(mode)
            self.stepStepperNext(inv, hoverTarget: hoverTarget, rowIdentifier: "visualizer.overlay.mode")
        }

        self.assertLiveness(inv, context: "before appearance switch")

        SettingsCrawlTests.openSettings(app, inv)
        let anchor = inv.element("settings.sidebar.general")
        XCTAssertTrue(anchor.waitForExistence(timeout: 10), "Settings never opened")
        SettingsCrawlTests.navigate(inv, app, to: "appearance", anchor: anchor)

        for scheme in ["Dark", "Light", "System"] {
            let option = app.radioButtons[scheme]
            XCTAssertTrue(option.waitForExistence(timeout: 6), "appearance option \(scheme) missing")
            option.click()
            inv.settle(0.5)
        }
        for accent in ["blue", "green"] {
            let swatch = inv.element("settings.appearance.accent.\(accent)")
            XCTAssertTrue(swatch.waitForExistence(timeout: 6), "accent swatch \(accent) missing")
            SettingsCrawlTests.tap(swatch)
            inv.settle(0.5)
        }
        inv.closeFrontWindow()

        self.assertLiveness(inv, context: "after appearance switch")
    }

    // MARK: Helpers

    /// Reads a plain readout element's `.accessibilityValue` (the mode/
    /// palette name siblings, or the FPS host). No hover needed: these all
    /// live outside `VisualizerControlOverlay`'s fade chain by design (see
    /// `LivenessAccessibilityValue`'s doc comment) and stay queryable
    /// whether or not the overlay itself is currently visible. Guards on
    /// `.exists`: touching `.value` on a query with zero matches hard-fails
    /// the test via XCTest's own snapshot resolution, rather than returning
    /// nil like a normal missing value.
    private func readValue(_ inv: MenuInvoker, identifier: String) -> String? {
        let element = inv.element(identifier)
        guard element.exists else { return nil }
        let text = String(describing: element.value ?? "")
        return text.isEmpty ? nil : text
    }

    /// Clicks a stepper row's "next" chevron. The row itself — unlike the
    /// value readouts above — lives inside `controlsCard`, which fades
    /// `fadeAfter` seconds (3s in the pane/mini player, 2s in fullscreen)
    /// after the last interaction, and is non-interactive while faded,
    /// so a real hover over the surrounding surface always precedes the
    /// tap. `hoverTarget` must be large enough to land inside the
    /// surface's own `.onHover`/`.onContinuousHover` region: the whole
    /// pane (main pane) or the whole window (mini player, fullscreen),
    /// since none of those regions carry a dedicated identifier of their
    /// own. Uses a coordinate hover, not `XCUIElement.hover()`: the latter
    /// never revealed the mini player's overlay in testing, even after
    /// repeated retries, while a coordinate-based hover on the exact same
    /// window did (phase 33, found empirically).
    /// `.accessibilityElement(children: .ignore)` combines the row's
    /// two chevron buttons out of the AX tree (it is one adjustable
    /// element for VoiceOver), so a coordinate tap near the row's trailing
    /// edge is what actually lands on the button — a real click hits
    /// whatever NSView renders there regardless of AX combining.
    private func stepStepperNext(_ inv: MenuInvoker, hoverTarget: XCUIElement, rowIdentifier: String) {
        hoverTarget.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        inv.settle(0.2)
        let row = inv.element(rowIdentifier)
        // Touching `.coordinate` on a query with zero matches hard-fails the
        // test via XCTest's own snapshot resolution rather than a normal
        // XCTFail, so wait for real existence first — the reveal above can
        // race the overlay's own re-layout on a slower run.
        guard row.waitForExistence(timeout: 3) else {
            XCTFail("stepper row \(rowIdentifier) never became hittable")
            return
        }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        inv.settle(0.3)
    }

    /// Parses the leading integer off an accessibility value like "58 fps".
    private static func parsedFPS(_ text: String) -> Double? {
        let digits = text.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Double(digits)
    }

    /// The design doc's exact liveness contract: FPS > 10 after a 2s settle,
    /// still > 10 five seconds later (guards against a renderer that spikes
    /// briefly then dies).
    private func assertLiveness(_ inv: MenuInvoker, context: String) {
        let host = inv.element("visualizerPane.host")
        XCTAssertTrue(host.waitForExistence(timeout: 6), "visualizer host missing (\(context))")

        inv.settle(2.0)
        guard let fps1 = Self.parsedFPS(String(describing: host.value ?? "")) else {
            XCTFail("could not read FPS from visualizer host after 2s (\(context))")
            return
        }
        XCTAssertGreaterThan(fps1, 10, "FPS too low after 2s (\(context)): \(fps1)")

        inv.settle(5.0)
        guard let fps2 = Self.parsedFPS(String(describing: host.value ?? "")) else {
            XCTFail("could not read FPS from visualizer host after 7s (\(context))")
            return
        }
        XCTAssertGreaterThan(fps2, 10, "FPS dropped below floor after 5 more seconds (\(context)): \(fps2)")
    }

    /// Plays the fixture queue; the pane/mini player/full screen are opened
    /// separately by each test.
    private func startPlayback(_ app: XCUIApplication, _ inv: MenuInvoker) {
        inv.selectSidebar("Songs")
        app.firstTrackRow.doubleClick()
        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "fixture never started playing")
        inv.settle(0.5)
    }

    /// Plays the fixture queue, then opens the visualizer pane from the toolbar.
    private func startPlaybackAndOpenPane(_ app: XCUIApplication, _ inv: MenuInvoker) {
        self.startPlayback(app, inv)
        inv.element("toolbar.visualizer").click()
        // The pane's first open in a run also spins up the audio tap and,
        // for a Metal mode, a one-time shader-pipeline compile; give it more
        // room than the default 8s budget.
        inv.waitFor("visualizer pane opens", timeout: 15) { inv.element("visualizerPane").exists }
        inv.waitFor("mode value populates") { self.readValue(inv, identifier: "visualizer.overlay.mode.value") != nil }
    }

    /// Toggles the mini player, then cycles its layout button (phase 32's
    /// mechanism, `MiniPlayerWindowTests.layoutName`) until it reads "visualizer".
    private func openMiniPlayerInVisualizerLayout(_ app: XCUIApplication, _ inv: MenuInvoker) {
        inv.invoke(["View", "Toggle Miniplayer"])
        XCTAssertTrue(
            app.windows["Mini Player"].waitForExistence(timeout: 8),
            "mini player window never opened"
        )
        let layoutButton = inv.element("miniPlayer.layout")
        XCTAssertTrue(layoutButton.waitForExistence(timeout: 6), "mini player layout button missing")
        for _ in 0 ..< MiniPlayerWindowTests.expectedLayouts.count {
            if MiniPlayerWindowTests.layoutName(from: layoutButton.label) == "visualizer" {
                inv.waitFor("mode value populates (mini player)") {
                    self.readValue(inv, identifier: "visualizer.overlay.mode.value") != nil
                }
                return
            }
            layoutButton.click()
            inv.settle(0.4)
        }
        XCTFail("mini player never reached the visualizer layout")
    }

    /// Opens the fullscreen visualizer window from the View menu.
    private func openFullScreenVisualizer(_ app: XCUIApplication, _ inv: MenuInvoker) {
        inv.invoke(["View", "Open Fullscreen Visualizer"])
        inv.waitFor("fullscreen visualizer opens", timeout: 15) { app.windows["Visualizer"].exists }
        inv.waitFor("mode value populates (full screen)") {
            self.readValue(inv, identifier: "visualizer.overlay.mode.value") != nil
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
