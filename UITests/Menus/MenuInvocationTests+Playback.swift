import XCTest

// MARK: Playback transport and modes

/// The Playback part of the invocation pass. `playbackItems` runs its steps
/// in the order below; each step starts from the state the one before it
/// left, so the order is part of the test.
extension MenuInvocationTests {
    func playbackItems(_ app: XCUIApplication, _ inv: MenuInvoker) {
        self.transportItems(app, inv)
        self.volumeAndModeItems(inv)
        self.speedItems(inv)
        self.sleepTimerItems(inv)
        self.navigationItems(app, inv)
        self.albumAndArtistPlaybackItems(app, inv)
        self.clearQueueItem(app, inv)
    }

    private func transportItems(_ app: XCUIApplication, _ inv: MenuInvoker) {
        self.run(["Playback", "Play / Pause"], inv)
        XCTAssertTrue(app.waitUntilNotPlaying(timeout: 10), "pause never took")
        self.run(["Playback", "Play / Pause"], inv)
        XCTAssertTrue(app.waitUntilPlaying(timeout: 10), "resume never took")

        self.run(["Playback", "Next Track"], inv)
        inv.waitFor("strip advances to the other tone") {
            self.stripTitle(inv).contains(self.otherTone)
        }
        self.run(["Playback", "Previous Track"], inv)
        inv.waitFor("strip returns to the first tone") {
            self.stripTitle(inv).contains(self.firstTone)
        }
        self.run(["Playback", "Restart Track"], inv)
        XCTAssertTrue(app.waitUntilPlaying(timeout: 10), "restart stopped playback")
        XCTAssertTrue(self.stripTitle(inv).contains(self.firstTone))
    }

    private func volumeAndModeItems(_ inv: MenuInvoker) {
        self.run(["Playback", "Mute"], inv)
        inv.waitFor("mute button flips") { inv.element("nowPlayingStrip.mute").label == "Unmute" }
        self.run(["Playback", "Unmute"], inv)
        inv.waitFor("mute button restores") { inv.element("nowPlayingStrip.mute").label == "Mute" }

        let volume = { self.volumePercent(inv) }
        let startVolume = volume()
        self.run(["Playback", "Decrease Volume"], inv)
        inv.waitFor("volume drops") { volume() < startVolume }
        self.run(["Playback", "Increase Volume"], inv)
        inv.waitFor("volume restores") { volume() == startVolume }

        self.run(["Playback", "Toggle Shuffle"], inv)
        inv.waitFor("shuffle on") { (inv.element("nowPlayingStrip.shuffle").value as? String) == "on" }
        self.run(["Playback", "Toggle Shuffle"], inv)
        inv.waitFor("shuffle off") { (inv.element("nowPlayingStrip.shuffle").value as? String) == "off" }

        let repeatValue = { inv.element("nowPlayingStrip.repeat").value as? String }
        let repeatStart = repeatValue()
        self.run(["Playback", "Cycle Repeat"], inv)
        inv.waitFor("repeat cycles") { repeatValue() != repeatStart }
        self.run(["Playback", "Cycle Repeat"], inv)
        self.run(["Playback", "Cycle Repeat"], inv)
        inv.waitFor("repeat completes the cycle") { repeatValue() == repeatStart }

        let stopAfterLabel = { inv.element("nowPlayingStrip.stopAfterCurrent").label }
        let stopAfterStart = stopAfterLabel()
        self.run(["Playback", "Toggle Stop After Current"], inv)
        inv.waitFor("stop-after arms") { stopAfterLabel() != stopAfterStart }
        self.run(["Playback", "Toggle Stop After Current"], inv)
        inv.waitFor("stop-after disarms") { stopAfterLabel() == stopAfterStart }
    }

    private func speedItems(_ inv: MenuInvoker) {
        // Speed surfaces on the strip's speed control, labelled
        // "Speed: <rate>" (read directly, not via a whole-window snapshot
        // that an open/closing menu can occlude).
        let speed = { inv.element("nowPlayingStrip.speedPicker").label }
        for rate in ["0.75×", "1.25×", "1.5×", "2×"] {
            self.run(["Playback", "Playback Speed", rate], inv)
            inv.waitFor("strip speed is \(rate)") { speed().contains(rate) }
        }
        self.run(["Playback", "Playback Speed", "1×"], inv)
        inv.waitFor("speed returns to unity") { speed().contains("1×") }
        self.run(["Playback", "Increase Speed"], inv)
        inv.waitFor("speed steps up") { speed().contains("1.25×") }
        self.run(["Playback", "Decrease Speed"], inv)
        inv.waitFor("speed steps back to unity") { speed().contains("1×") }
        self.run(["Playback", "Reset Speed to 1×"], inv)
        inv.waitFor("reset holds unity") { speed().contains("1×") }
    }

    private func sleepTimerItems(_ inv: MenuInvoker) {
        // Sleep presets flip the strip control's text off its idle text. Read
        // label and title together: the control is a SwiftUI Menu, and on
        // macOS 27 its accessibility label lands in the title while the label
        // is the moon symbol's own "do not disturb", whatever the state.
        let sleepLabel = {
            let control = inv.element("nowPlayingStrip.sleepTimer")
            return "\(control.label) | \(control.title)"
        }
        let idleSleep = sleepLabel()
        for preset in ["15 min", "30 min", "45 min", "1 hr", "1 hr 30 min", "2 hr"] {
            self.run(["Playback", "Sleep Timer", preset], inv)
            inv.waitFor("sleep timer arms (\(preset))") { sleepLabel() != idleSleep }
        }
        self.run(["Playback", "Sleep Timer", "Off"], inv)
        inv.waitFor("sleep timer clears") { sleepLabel() == idleSleep }
    }

    private func navigationItems(_ app: XCUIApplication, _ inv: MenuInvoker) {
        // Navigation postconditions ride on the window title.
        inv.selectSidebar("Albums")
        self.run(["Playback", "Jump to Current Track"], inv)
        inv.waitFor("jump returns to Songs") { app.firstTrackRow.exists }
        // Pushed detail views keep the sidebar destination's window title
        // (flagged: cosmetic staleness), so the postconditions use each
        // detail's own furniture: the album header's "Shuffle Album"
        // button, and the artist detail's album tile grid.
        self.run(["Playback", "Go to Current Album"], inv)
        inv.waitFor("album detail opens") { app.buttons["Shuffle Album"].exists }
        // A pushed detail keeps the sidebar row selected, so clicking the
        // row is a no-op; only the toolbar back button leaves the detail.
        inv.element("toolbar.back").click()
        inv.waitFor("back on the plain Songs list") { !app.buttons["Shuffle Album"].exists }
        self.run(["Playback", "Go to Current Artist"], inv)
        inv.waitFor("artist detail opens") { app.staticTexts["Albums (1)"].exists }
        inv.element("toolbar.back").click()
        inv.waitFor("artist detail closed") { !app.staticTexts["Albums (1)"].exists }
    }

    private func albumAndArtistPlaybackItems(_ app: XCUIApplication, _ inv: MenuInvoker) {
        // Album/artist playback replaces the queue from the selection's
        // context; the strip must keep (or return to) a fixture tone.
        self.selectAllSongs(inv)
        self.run(["Track", "Play Album"], inv)
        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "Play Album never started")
        inv.waitFor("album playback shows a fixture tone") {
            self.stripTitle(inv).contains("E2E Tone")
        }
        self.selectAllSongs(inv)
        self.run(["Track", "Shuffle Album"], inv)
        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "Shuffle Album never started")
        inv.waitFor("shuffled album plays a fixture tone") {
            self.stripTitle(inv).contains("E2E Tone")
        }
        self.selectAllSongs(inv)
        self.run(["Track", "Play Artist"], inv)
        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "Play Artist never started")
        inv.waitFor("artist queue plays a fixture tone") {
            self.stripTitle(inv).contains("E2E Tone")
        }
    }

    private func clearQueueItem(_ app: XCUIApplication, _ inv: MenuInvoker) {
        // Destructive, against throwaway fixture state: confirm the
        // "Clear the queue?" dialog, then the display must clear (the
        // resting-queue sync fixed in this phase).
        self.run(["Playback", "Clear Queue"], inv)
        // Scope the confirm button to the confirmation container (a sheet
        // or dialog by platform): the menu item of the same name is still
        // in the app-wide tree, so an unscoped query is ambiguous.
        inv.waitFor("clear-queue confirmation") {
            self.clearQueueConfirm(app).exists
        }
        self.clearQueueConfirm(app).click()
        // When idle the title renders as plain text (not the jump button
        // stripTitle reads), so assert on the visible "Not playing" label.
        inv.waitFor("strip clears") { app.staticTexts["Not playing"].exists }
        XCTAssertTrue(app.waitUntilNotPlaying(timeout: 10))
    }

    /// The strip's title element: its label is "Jump to <track> in track
    /// list" while a track plays and "Not playing" when idle, so title
    /// postconditions match by containment.
    func stripTitle(_ inv: MenuInvoker) -> String {
        let element = inv.element("nowPlayingStrip.title.button")
        return element.exists ? element.label : ""
    }

    /// XCUITest reports slider values in whatever form AX resolves first:
    /// a normalized number (0.85), a percent string, or the custom
    /// "85 percent" accessibility value. Normalize them all to 0-100.
    /// The confirm button of the "Clear the queue?" dialog, scoped to
    /// whichever container the platform presents it in.
    private func clearQueueConfirm(_ app: XCUIApplication) -> XCUIElement {
        for container in [app.sheets.firstMatch, app.dialogs.firstMatch] where container.exists {
            let button = container.buttons["Clear Queue"]
            if button.exists {
                return button
            }
        }
        return app.sheets.firstMatch.buttons["Clear Queue"]
    }

    private func volumePercent(_ inv: MenuInvoker) -> Int {
        let element = inv.element("nowPlayingStrip.volume")
        guard element.exists else { return -1 }
        if let number = element.value as? NSNumber {
            let raw = number.doubleValue
            return raw <= 1.0 ? Int((raw * 100).rounded()) : Int(raw)
        }
        if let string = element.value as? String {
            if let raw = Double(string) {
                return raw <= 1.0 ? Int((raw * 100).rounded()) : Int(raw)
            }
            if let digits = Int(string.filter(\.isNumber)) {
                return digits
            }
        }
        return -1
    }
}
