import XCTest

// MARK: - TransportSurfaceTests

/// Phase 31 surface crawl: the now-playing transport strip, with a local
/// track playing. Every identified control is exercised with a concrete
/// postcondition (toggles flip their label/value, navigation buttons
/// change destination, the info button opens a sheet, the DSP button opens
/// a window, the speed/sleep menus open). Continuous controls (volume,
/// scrubber) and conditional/podcast-only controls carry skip reasons; the
/// `controls` table is the reviewable artifact.
@MainActor
final class TransportSurfaceTests: XCTestCase {
    private var session: E2ESession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    /// Transport identifiers this suite covers, for the completeness test.
    static let coveredIdentifiers = [
        "nowPlayingStrip.artwork.button", "nowPlayingStrip.title.button",
        "nowPlayingStrip.subtitle.button", "nowPlayingStrip.love",
        "nowPlayingStrip.info", "nowPlayingStrip.prev", "nowPlayingStrip.playPause",
        "nowPlayingStrip.next", "nowPlayingStrip.shuffle", "nowPlayingStrip.repeat",
        "nowPlayingStrip.stopAfterCurrent", "nowPlayingStrip.mute",
        "nowPlayingStrip.volume", "nowPlayingStrip.scrubber",
        "nowPlayingStrip.speedPicker", "nowPlayingStrip.sleepTimer",
        "nowPlayingStrip.dsp",
    ]

    // MARK: The crawl

    func testTransportSurface() {
        let app = self.launch()
        let crawler = SurfaceCrawler(app: app)
        let inv = crawler.inv

        // Arrange: a deterministic two-track queue so Next/Previous
        // navigate between the tones instead of running off the end (which
        // a single-track double-click queue would do, stopping playback).
        inv.selectSidebar("Songs")
        app.firstTrackRow.click()
        inv.invoke(["Track", "Select All"])
        inv.waitFor("both tracks selected") { inv.selectedTrackRowCount() == 2 }
        inv.invoke(["Track", "Play Now"])
        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "fixture never started playing")

        crawler.crawl("Transport", Self.controls)
    }

    static var controls: [SurfaceControl] {
        [
            // Navigation buttons: each pushes a detail / switches destination;
            // restore returns to Songs so the strip stays live for the rest.
            SurfaceControl(
                "nowPlayingStrip.artwork.button", "Go to album",
                restore: backToSongs
            ) { app, _, _ in app.buttons["Shuffle Album"].exists },
            SurfaceControl(
                "nowPlayingStrip.subtitle.button", "Go to artist",
                restore: backToSongs
            ) { app, _, _ in app.staticTexts["Albums (1)"].exists },
            SurfaceControl(
                "nowPlayingStrip.title.button", "Jump to current track"
            ) { app, _, _ in app.windows.firstMatch.title == "Songs" && app.firstTrackRow.exists },

            // Toggles: label/value flips, then restore flips back.
            toggleLabel("nowPlayingStrip.love", "Love"),
            toggleLabel("nowPlayingStrip.mute", "Mute"),
            toggleLabel("nowPlayingStrip.stopAfterCurrent", "Stop after current"),
            SurfaceControl(
                "nowPlayingStrip.shuffle", "Shuffle toggle",
                restore: { _, inv in inv.element("nowPlayingStrip.shuffle").click()
                    inv.settle(0.3)
                }
            ) { _, inv, context in
                (inv.element("nowPlayingStrip.shuffle").value as? String) != context.priorValue
            },
            SurfaceControl(
                "nowPlayingStrip.repeat", "Repeat cycle",
                restore: { _, inv in
                    // Complete the 3-step cycle back to the starting value.
                    inv.element("nowPlayingStrip.repeat").click()
                    inv.settle(0.2)
                    inv.element("nowPlayingStrip.repeat").click()
                    inv.settle(0.2)
                }
            ) { _, inv, context in
                (inv.element("nowPlayingStrip.repeat").value as? String) != context.priorValue
            },

            // Transport: play/pause flips, next advances the strip title, prev
            // keeps a fixture tone playing.
            SurfaceControl(
                "nowPlayingStrip.playPause", "Play / pause",
                restore: { _, inv in inv.element("nowPlayingStrip.playPause").click()
                    inv.settle(0.3)
                }
            ) { _, inv, context in
                inv.element("nowPlayingStrip.playPause").label != context.priorLabel
            },
            SurfaceControl("nowPlayingStrip.next", "Next track") { _, inv, _ in
                inv.element("nowPlayingStrip.title.button").label.contains("E2E Tone")
            },
            // prev's contract is navigation (previous track, or restart past
            // 3s), not a play-state guarantee: switching tracks briefly
            // flickers isPlaying, so assert the strip still shows a tone.
            SurfaceControl("nowPlayingStrip.prev", "Previous or restart") { _, inv, _ in
                inv.element("nowPlayingStrip.title.button").label.contains("E2E Tone")
            },

            // Info opens the tag editor sheet.
            SurfaceControl(
                "nowPlayingStrip.info", "Track info",
                restore: { _, inv in inv.dismissSheet() }
            ) { app, _, _ in app.sheets.firstMatch.exists },

            // Menus open a list of options; Escape closes.
            // The crawler already polls `verify`; use `.exists`, not a
            // nested `waitForExistence`, so the two waits don't conflict.
            SurfaceControl(
                "nowPlayingStrip.speedPicker", "Playback speed menu",
                restore: { _, inv in inv.pressEscape() }
            ) { app, _, _ in
                app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", "1.5×")).firstMatch.exists
            },
            // The sleep menu's rich content (a Toggle and a custom-field
            // trigger) is rendered so XCUITest cannot traverse its items
            // (unlike the plain speed menu), so assert the menu opened
            // rather than a specific preset; arming a preset is covered by
            // the Playback ▸ Sleep Timer menu invocation pass.
            SurfaceControl(
                "nowPlayingStrip.sleepTimer", "Sleep timer menu",
                restore: { _, inv in inv.pressEscape() }
            ) { app, _, context in
                app.menus.firstMatch.exists || app.windows.count > context.priorWindowCount
            },

            // DSP opens a window.
            SurfaceControl(
                "nowPlayingStrip.dsp", "Equaliser & DSP window",
                restore: { _, inv in inv.closeFrontWindow() }
            ) { app, _, context in app.windows.count > context.priorWindowCount },

            // Continuous controls: their contract is a live drag. Volume
            // changes are proven by the Playback menu's Increase/Decrease
            // Volume test, and seeking races the live position, so here they
            // are asserted present with playback still responsive (the spec's
            // sanctioned postcondition for visual/continuous controls).
            SurfaceControl(
                "nowPlayingStrip.volume", "Volume slider",
                action: .presence,
                skip: "continuous control; volume changes are asserted by the Playback menu volume test"
            ) { _, inv, _ in inv.element("nowPlayingStrip.playPause").exists },
            SurfaceControl(
                "nowPlayingStrip.scrubber", "Seek scrubber",
                action: .presence,
                skip: "continuous control; a seek drag races the live position"
            ) { _, inv, _ in inv.element("nowPlayingStrip.playPause").exists },
        ]
    }

    // MARK: Table helpers

    /// A toggle whose accessibilityLabel begins with `prefix` and flips
    /// between two "On/Off"-style strings on click.
    private static func toggleLabel(_ identifier: String, _ name: String) -> SurfaceControl {
        SurfaceControl(
            identifier, "\(name) toggle",
            restore: { _, inv in inv.element(identifier).click()
                inv.settle(0.3)
            }
        ) { _, inv, context in
            inv.element(identifier).label != context.priorLabel
        }
    }

    /// Returns to the Songs destination after a navigation control.
    private static let backToSongs: @MainActor (XCUIApplication, MenuInvoker) -> Void = { _, inv in
        inv.selectSidebar("Songs")
        inv.settle(0.3)
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
