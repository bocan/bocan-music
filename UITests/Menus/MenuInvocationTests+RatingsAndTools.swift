import XCTest

/// The rating, ReplayGain batch and Tools menu parts of the invocation pass,
/// with the helpers they share.
extension MenuInvocationTests {
    // MARK: Ratings and ReplayGain batches

    func ratingAndBatchItems(_ app: XCUIApplication, _ inv: MenuInvoker) {
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

    func selectAllSongs(_ inv: MenuInvoker) {
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

    // MARK: Tools

    func toolsItems(_ app: XCUIApplication, _ inv: MenuInvoker) {
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
}
