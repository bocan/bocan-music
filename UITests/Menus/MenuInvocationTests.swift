import XCTest

// MARK: - MenuInvocationTests

/// Phase 30 invocation pass: every app-owned menu item is invoked once in
/// fixture mode with a postcondition, in one scripted sequence whose state
/// each step builds on (queue items are inserted before playback starts,
/// destructive items run against throwaway fixture state, panels are
/// dismissed by the interpreter before the next step). Items that cannot
/// be invoked carry a written reason in `skips`, and the sequence records
/// what it actually invoked so the completeness assertion at the end
/// proves manifest coverage empirically.
@MainActor
final class MenuInvocationTests: XCTestCase {
    private var session: E2ESession!
    private var covered: Set<String> = []
    /// The tone Play Now started with (queue follows table sort order,
    /// which does not match title order) and its counterpart.
    private var firstTone = ""
    private var otherTone = ""

    override func setUp() async throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    // MARK: Skips

    struct Skip {
        let menu: String
        let item: String
        let reason: String
    }

    static let skips: [Skip] = [
        Skip(
            menu: "Bòcan Music", item: "Check for Updates…",
            reason: "Sparkle cannot check in unsigned debug/E2E builds; the item is disabled"
        ),
        Skip(
            menu: "View", item: "View as",
            reason: "inert header row for the toggle pair below it"
        ),
        Skip(
            menu: "View", item: "as List",
            reason: "disabled off the collection listings; phase 31 exercises it with the Artists surface"
        ),
        Skip(
            menu: "View", item: "as Album Grid",
            reason: "disabled off the collection listings; phase 31 exercises it with the Artists surface"
        ),
        Skip(
            menu: "Track", item: "Identify Track…",
            reason: "opens a sheet that fires a live AcoustID lookup; hermetic network is phase 34"
        ),
        Skip(
            menu: "Track", item: "Reveal in Finder",
            reason: "activates Finder over the app; no in-app postcondition to assert"
        ),
        Skip(
            menu: "Track", item: "Fetch Lyrics from LRClib",
            reason: "hidden behind lyrics.lrclibEnabled, which the pass pins off to avoid live LRClib calls (phase 34)"
        ),
        Skip(
            menu: "Track", item: "Clear Lyrics",
            reason: "disabled: fixture tones carry no stored lyrics to clear"
        ),
        Skip(
            menu: "Tools", item: "Analyse Provenance…",
            reason: "only immediate feedback is a 2s toast (a SwiftUI overlay XCUITest does not surface); its persistent result lives in Library Summary ▸ Audio Quality, exercised by the phase 32 window crawl"
        ),
    ]

    // MARK: The pass

    func testInvokeEveryMenuItem() {
        // Only LRClib is pinned (it must never fire a live lookup). Pane
        // visibility must NOT be pinned: an argument-domain value
        // overrides reads even after the toggle writes, so the pinned key
        // would freeze the pane and its menu title forever. The toggle
        // steps adapt to whatever state the app starts in instead.
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        let inv = MenuInvoker(app: app)

        self.windowItems(app, inv)
        self.viewToggleItems(app, inv)
        self.fileItems(app, inv)
        self.findItem(app, inv)
        self.queueAndSelectionItems(app, inv)
        self.playbackItems(app, inv)
        self.ratingAndBatchItems(app, inv)
        self.toolsItems(app, inv)
        self.fullscreenVisualizerItem(app, inv)

        self.assertManifestCoverage()
    }

    // MARK: Window-opening items

    private func windowItems(_ app: XCUIApplication, _ inv: MenuInvoker) {
        for path in [
            ["Bòcan Music", "About Bòcan"],
            ["Help", "Bòcan Music Help"],
            ["Help", "Notices & Licences…"],
            ["Help", "Log Console"],
            ["Tools", "Library Summary…"],
            ["View", "Equaliser & DSP…"],
        ] {
            let before = inv.windowCount
            self.run(path, inv)
            inv.waitFor("\(path.last!) window") { inv.windowCount == before + 1 }
            inv.closeFrontWindow()
            inv.waitFor("\(path.last!) window to close") { inv.windowCount == before }
        }

        // Deep-links to Settings ▸ Sources; the Settings window titles
        // itself after the pane.
        let before = inv.windowCount
        self.run(["File", "Music Sources…"], inv)
        inv.waitFor("Sources settings window") {
            inv.windowCount == before + 1 && app.windows["Sources"].exists
        }
        inv.closeFrontWindow()
        inv.waitFor("settings to close") { inv.windowCount == before }

        self.run(["View", "Show Recent Scrobbles"], inv)
        inv.waitFor("recent scrobbles sheet") { app.sheets.firstMatch.exists }
        inv.dismissSheet()
        inv.waitFor("sheet gone") { !app.sheets.firstMatch.exists }
    }

    // MARK: View pane toggles

    private func viewToggleItems(_ app: XCUIApplication, _ inv: MenuInvoker) {
        self.togglePane(inv, show: "Show Lyrics", hide: "Hide Lyrics")
        self.togglePane(inv, show: "Show Visualizer", hide: "Hide Visualizer")

        self.run(["View", "Toggle Miniplayer"], inv)
        inv.waitFor("miniplayer chrome") { inv.element("miniPlayer.layout").exists }
        self.run(["View", "Toggle Miniplayer"], inv)
        inv.waitFor("main window back") { app.firstTrackRow.exists }
    }

    /// Drives a naming sheet (New Playlist / New Playlist Folder): types
    /// the name and commits with Create. The commit dismissing the sheet
    /// is the postcondition; the sidebar row itself materializes lazily
    /// off-screen (SwiftUI List), so its AX presence is not assertable
    /// here (the sidebar surfaces belong to phase 31).
    private func createViaSheet(
        _ inv: MenuInvoker,
        path: [String],
        name: String,
        commitsInlineRename: Bool = false
    ) {
        let app = inv.app
        self.run(path, inv)
        let sheet = app.sheets.firstMatch
        inv.waitFor("\(path.last!) sheet") { sheet.exists }
        let field = sheet.textFields.firstMatch
        inv.waitFor("\(path.last!) name field") { field.exists }
        field.click()
        inv.app.typeKey("a", modifierFlags: .command) // replace the prefilled default
        field.typeText(name)
        sheet.buttons["Create"].click()
        inv.waitFor("\(path.last!) sheet commits and closes") { !sheet.exists }
        if commitsInlineRename {
            // The sidebar row is now a focused inline text field; commit it
            // so keyboard focus returns to the app (Return keeps the name).
            inv.settle(0.5)
            app.typeKey(.return, modifierFlags: [])
            inv.settle(0.3)
        }
    }

    /// Invokes whichever of the Show/Hide pair the menu currently offers,
    /// asserts the title flips, then restores the starting state (the
    /// pane keys leak from the shared container, so the start is not
    /// deterministic).
    private func togglePane(_ inv: MenuInvoker, show: String, hide: String) {
        let first = inv.menuHasItem("View", show) ? show : hide
        let second = first == show ? hide : show
        self.run(["View", first], inv)
        XCTAssertTrue(inv.menuHasItem("View", second), "\(first) did not flip to \(second)")
        self.run(["View", second], inv)
        XCTAssertTrue(inv.menuHasItem("View", first), "\(second) did not flip back to \(first)")
    }

    // MARK: File menu

    private func fileItems(_ app: XCUIApplication, _ inv: MenuInvoker) {
        // Both creation flows present a naming sheet with a Create button.
        // A new folder additionally drops into inline rename on the sidebar
        // row (create-then-rename UX), so its editor must be committed.
        self.createViaSheet(inv, path: ["File", "New Playlist…"], name: "E2E Playlist")
        self.createViaSheet(
            inv,
            path: ["File", "New Playlist Folder…"],
            name: "E2E Folder",
            commitsInlineRename: true
        )

        // Creating rows navigates the sidebar; return to Songs so later
        // steps find the library table.
        inv.selectSidebar("Songs")

        self.run(["File", "New Smart Playlist…"], inv)
        inv.waitFor("smart playlist sheet") { app.sheets.firstMatch.exists }
        inv.dismissSheet()
        inv.waitFor("sheet gone") { !app.sheets.firstMatch.exists }

        self.run(["File", "Import Playlist…"], inv)
        inv.waitFor("import chooser") { app.sheets.firstMatch.exists || app.dialogs.firstMatch.exists }
        inv.pressEscape()
        inv.waitFor("chooser gone") { !app.sheets.firstMatch.exists && !app.dialogs.firstMatch.exists }

        // Raw NSOpenPanels surface as extra windows, not sheets/dialogs.
        for item in ["Add Folder to Library…", "Add Files to Library…"] {
            let before = inv.windowCount
            self.run(["File", item], inv)
            inv.waitFor("open panel after \(item)") {
                app.sheets.firstMatch.exists || app.dialogs.firstMatch.exists
                    || inv.windowCount > before
            }
            inv.pressEscape()
            inv.waitFor("panel gone after \(item)") {
                !app.sheets.firstMatch.exists && !app.dialogs.firstMatch.exists
                    && inv.windowCount == before
            }
        }

        for item in ["Quick Rescan Library", "Full Rescan Library"] {
            self.run(["File", item], inv)
            let dismiss = app.buttons["scanBanner.dismiss"]
            inv.waitFor("scan summary after \(item)", timeout: 15) { dismiss.exists }
            // The summary auto-hides after 3s; wait it out so the next
            // step starts with a clean top inset.
            inv.waitFor("summary auto-hide") { !dismiss.exists }
        }
    }

    // MARK: Find

    private func findItem(_ app: XCUIApplication, _ inv: MenuInvoker) {
        self.run(["Edit", "Find"], inv)
        let field = app.searchFields.firstMatch
        inv.waitFor("search field") { field.exists }
        app.typeText("probe")
        inv.waitFor("typed text reached the focused search field") {
            (field.value as? String) == "probe"
        }
        // Clear and unfocus so the library shows all rows again. The
        // debounced reload can drop the field's focus, so re-focus with a
        // click before touching the keyboard (a blind ⌘A+delete would land
        // on the track table instead).
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        inv.waitFor("search text cleared") { (field.value as? String) != "probe" }
        inv.pressEscape()
        inv.selectSidebar("Songs")
        inv.waitFor("library restored") { app.firstTrackRow.exists }
    }

    // MARK: Queue inserts, then playback start

    private func queueAndSelectionItems(_ app: XCUIApplication, _ inv: MenuInvoker) {
        // Selection items first (nothing playing yet).
        app.firstTrackRow.click()
        self.run(["Track", "Select All"], inv)
        inv.waitFor("both rows selected") { inv.selectedTrackRowCount() == 2 }
        self.run(["Track", "Deselect All"], inv)
        inv.waitFor("selection cleared") { inv.selectedTrackRowCount() == 0 }

        app.firstTrackRow.click()
        self.run(["Track", "Get Info"], inv)
        inv.waitFor("tag editor sheet") { app.sheets.firstMatch.exists }
        inv.dismissSheet()
        inv.waitFor("tag editor gone") { !app.sheets.firstMatch.exists }

        // Queue inserts verified through Up Next, which covers Show Up
        // Next itself (window titles follow the destination).
        app.firstTrackRow.click()
        self.run(["Track", "Play Next"], inv)
        self.run(["Playback", "Show Up Next"], inv)
        inv.waitFor("Up Next shows the inserted track") {
            app.windows.firstMatch.title == "Up Next"
                && inv.mainWindowContains(E2ESession.fixtureTitle)
        }

        inv.selectSidebar("Songs")
        app.staticTexts["E2E Tone Two"].click()
        self.run(["Track", "Add to Queue"], inv)
        self.run(["Playback", "Show Up Next"], inv)
        inv.waitFor("Up Next shows the appended track") {
            inv.mainWindowContains("E2E Tone Two")
        }

        // Start playback with the full library selected so the queue has
        // two tracks for Next/Previous.
        inv.selectSidebar("Songs")
        app.firstTrackRow.click()
        app.typeKey("a", modifierFlags: .command)
        self.run(["Track", "Play Now"], inv)
        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "Play Now never started playback")
        inv.waitFor("strip shows a fixture tone") { self.stripTitle(inv).contains("E2E Tone") }
        self.firstTone = self.stripTitle(inv).contains("E2E Tone Two") ? "E2E Tone Two" : "E2E Tone One"
        self.otherTone = self.firstTone == "E2E Tone Two" ? "E2E Tone One" : "E2E Tone Two"

        // Loved state mirrors on the strip because the selection includes
        // the now-playing track.
        self.run(["Track", "Love / Unlove"], inv)
        inv.waitFor("strip love flips on") { inv.element("nowPlayingStrip.love").label == "Loved" }
        self.run(["Track", "Love / Unlove"], inv)
        inv.waitFor("strip love flips off") { inv.element("nowPlayingStrip.love").label == "Not Loved" }

        self.run(["Track", "Edit Lyrics…"], inv)
        inv.waitFor("lyrics editor") { app.sheets.firstMatch.exists || app.windows.count > 1 }
        inv.dismissSheet()
        if app.windows.count > 1 { inv.closeFrontWindow() }
    }

    // MARK: Playback transport and modes

    private func playbackItems(_ app: XCUIApplication, _ inv: MenuInvoker) {
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

        // Sleep presets flip the strip control's label off its idle text.
        let sleepLabel = { inv.element("nowPlayingStrip.sleepTimer").label }
        let idleSleep = sleepLabel()
        for preset in ["15 min", "30 min", "45 min", "1 hr", "1 hr 30 min", "2 hr"] {
            self.run(["Playback", "Sleep Timer", preset], inv)
            inv.waitFor("sleep timer arms (\(preset))") { sleepLabel() != idleSleep }
        }
        self.run(["Playback", "Sleep Timer", "Off"], inv)
        inv.waitFor("sleep timer clears") { sleepLabel() == idleSleep }

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

    // MARK: Ratings and ReplayGain batches

    private func ratingAndBatchItems(_ app: XCUIApplication, _ inv: MenuInvoker) {
        // Ratings are asserted through the seeded smart playlists (the
        // rating itself is not AX-visible in table rows). Both fixture
        // tracks are rated at once, so Unrated goes 2 to 0 and back.
        self.rate("★", inv, playlist: "Unrated", expectedRows: 0)
        self.rate("★★★★★", inv, playlist: "Five Stars", expectedRows: 2)
        self.rate("★★★★", inv, playlist: "Five Stars", expectedRows: 0)
        // Two and three stars have no distinguishing smart playlist; the
        // invariant (still rated, still not five-star) is what's left.
        self.rate("★★★", inv, playlist: "Unrated", expectedRows: 0)
        self.rate("★★", inv, playlist: "Five Stars", expectedRows: 0)
        self.rate("None", inv, playlist: "Unrated", expectedRows: 2)

        // Selection batch: completion state is shown (and dismissable) in
        // Settings ▸ ReplayGain.
        self.selectAllSongs(inv)
        self.run(["Track", "Compute Replay Gain"], inv)
        self.assertReplayGainCompletion(inv, after: "Compute Replay Gain")
    }

    private func rate(
        _ item: String,
        _ inv: MenuInvoker,
        playlist: String,
        expectedRows: Int
    ) {
        self.selectAllSongs(inv)
        self.run(["Track", "Rate", item], inv)
        // The rating write is async and the target smart playlist
        // re-evaluates its membership lazily; let the write commit, then
        // allow a generous window for the playlist's ValueObservation to
        // refresh. Assert on the header subtitle ("N songs · …"), not the
        // AppKit row count: a lingering second tracksTable from the prior
        // destination makes the row query ambiguous.
        inv.settle(1.0)
        inv.selectSidebar(playlist)
        // Verify by how many fixture titles the smart playlist lists (its
        // membership re-evaluates lazily off the async rating write, so a
        // generous window).
        inv.waitFor(
            "\(playlist) lists \(expectedRows) fixture(s) after Rate \(item)",
            timeout: 20
        ) { inv.visibleFixtureTitleCount() == expectedRows }
    }

    private func selectAllSongs(_ inv: MenuInvoker) {
        inv.selectSidebar("Songs")
        // Wait for the Songs list to actually populate before selecting:
        // clicking a row before the table reloads (e.g. arriving from an
        // empty smart-playlist view) selects nothing, and ⌘A then acts on
        // an empty table, so Rate would hit one track or none.
        inv.waitFor("Songs list populated") { inv.trackTableRowCount() == 2 }
        inv.app.firstTrackRow.click()
        // Select via the menu, not a raw ⌘A keystroke: the shortcut routes
        // through EditMenuRouting and only reaches the table when it holds
        // focus, which is not guaranteed right after a row click.
        self.run(["Track", "Select All"], inv)
        inv.waitFor("both tracks selected") { inv.selectedTrackRowCount() == 2 }
    }

    /// The strip's title element: its label is "Jump to <track> in track
    /// list" while a track plays and "Not playing" when idle, so title
    /// postconditions match by containment.
    private func stripTitle(_ inv: MenuInvoker) -> String {
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
            if button.exists { return button }
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
            if let digits = Int(string.filter(\.isNumber)) { return digits }
        }
        return -1
    }

    // MARK: Tools

    private func toolsItems(_ app: XCUIApplication, _ inv: MenuInvoker) {
        for item in ["Fetch Missing Cover Art…", "Find Duplicates…"] {
            self.run(["Tools", item], inv)
            inv.waitFor("\(item) sheet") { app.sheets.firstMatch.exists }
            inv.dismissSheet()
            inv.waitFor("\(item) sheet gone") { !app.sheets.firstMatch.exists }
        }

        // Analyse Provenance is skipped (see `skips`): its only immediate
        // main-window feedback is a transient toast.

        let beforeChooser = inv.windowCount
        self.run(["Tools", "Import Last.fm History…"], inv)
        inv.waitFor("history chooser") {
            app.sheets.firstMatch.exists || app.dialogs.firstMatch.exists
                || inv.windowCount > beforeChooser
        }
        inv.pressEscape()
        inv.waitFor("chooser gone") {
            !app.sheets.firstMatch.exists && !app.dialogs.firstMatch.exists
                && inv.windowCount == beforeChooser
        }

        self.run(["Tools", "Compute Missing ReplayGain"], inv)
        self.assertReplayGainCompletion(inv, after: "Compute Missing ReplayGain")
        self.run(["Tools", "Recompute ReplayGain"], inv)
        self.assertReplayGainCompletion(inv, after: "Recompute ReplayGain")
    }

    /// Opens Settings ▸ ReplayGain, waits for the batch completion state's
    /// Dismiss button, dismisses it, and closes Settings.
    private func assertReplayGainCompletion(_ inv: MenuInvoker, after item: String) {
        let app = inv.app
        app.typeKey(",", modifierFlags: .command)
        inv.waitFor("settings window") { app.windows.count > 1 }
        // Below-fold panes don't scroll on click; walk from General with
        // the keyboard (AppKit scrolls the keyboard selection).
        app.staticTexts["General"].firstMatch.click()
        inv.settle(0.3)
        for _ in 0 ..< 30 where app.windows["ReplayGain"].exists == false {
            app.typeKey(.downArrow, modifierFlags: [])
            inv.settle(0.15)
        }
        XCTAssertTrue(app.windows["ReplayGain"].exists, "never reached the ReplayGain pane")
        inv.waitFor("batch completion after \(item)", timeout: 30) {
            app.buttons["Dismiss"].exists
        }
        app.buttons["Dismiss"].click()
        inv.settle(0.3)
        inv.closeFrontWindow()
        inv.waitFor("settings closed") { app.windows.count == 1 }
    }

    // MARK: Fullscreen visualizer (last: it animates a space transition)

    private func fullscreenVisualizerItem(_ app: XCUIApplication, _ inv: MenuInvoker) {
        let before = inv.windowCount
        self.run(["View", "Open Fullscreen Visualizer"], inv)
        inv.waitFor("fullscreen visualizer window") { inv.windowCount == before + 1 }
        inv.settle(1.5)
        inv.pressEscape()
        if inv.windowCount > before { inv.closeFrontWindow() }
        inv.waitFor("visualizer window closed") { inv.windowCount == before }
    }

    // MARK: Coverage bookkeeping

    /// Invokes `path` and records it for the completeness assertion.
    private func run(_ path: [String], _ inv: MenuInvoker) {
        inv.invoke(path)
        self.covered.insert(path.last!)
    }

    /// Every app-owned manifest item must have been invoked (any of its
    /// titles) or carry a written skip reason; no skip may point at a
    /// manifest item that does not exist.
    private func assertManifestCoverage() {
        let skipTitles = Set(Self.skips.map(\.item))
        for skip in Self.skips {
            XCTAssertFalse(skip.reason.isEmpty, "skip \(skip.item) has no reason")
            XCTAssertTrue(
                MenuManifest.allItems.contains { $0.titles.contains(skip.item) },
                "skip \(skip.item) points at no manifest item"
            )
        }
        // Submenu parents (Rate, Playback Speed, Sleep Timer) are not
        // invocable actions; their children are what get invoked.
        for item in MenuManifest.allItems where !item.system && item.submenu.isEmpty {
            let invoked = !self.covered.isDisjoint(with: item.titles)
            let skipped = !skipTitles.isDisjoint(with: item.titles)
            XCTAssertTrue(
                invoked || skipped,
                "\(item.canonicalTitle): neither invoked nor skipped with a reason"
            )
        }
    }
}
