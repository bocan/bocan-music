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
    var firstTone = ""
    var otherTone = ""

    override func setUp() async throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    // The skip list (`Skip`, `skips`) is in `MenuInvocationTests+Skips.swift`.

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
        self.immersiveModeItems(inv)

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
            let title = self.run(path, inv)
            inv.waitFor("\(title) window") { inv.windowCount == before + 1 }
            inv.closeFrontWindow()
            inv.waitFor("\(title) window to close") { inv.windowCount == before }
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
        let title = self.run(path, inv)
        let sheet = app.sheets.firstMatch
        inv.waitFor("\(title) sheet") { sheet.exists }
        let field = sheet.textFields.firstMatch
        inv.waitFor("\(title) name field") { field.exists }
        field.click()
        inv.app.typeKey("a", modifierFlags: .command) // replace the prefilled default
        field.typeText(name)
        sheet.buttons["Create"].click()
        inv.waitFor("\(title) sheet commits and closes") { !sheet.exists }
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
        if app.windows.count > 1 {
            inv.closeFrontWindow()
        }
    }

    // The Playback step (`playbackItems`) is in `MenuInvocationTests+Playback.swift`;
    // the rating, ReplayGain batch and Tools steps (`ratingAndBatchItems`,
    // `toolsItems`) are in `MenuInvocationTests+RatingsAndTools.swift`.

    // MARK: Fullscreen visualizer (last: it animates a space transition)

    private func fullscreenVisualizerItem(_ app: XCUIApplication, _ inv: MenuInvoker) {
        let before = inv.windowCount
        self.run(["View", "Open Fullscreen Visualizer"], inv)
        inv.waitFor("fullscreen visualizer window") { inv.windowCount == before + 1 }
        inv.settle(1.5)
        inv.pressEscape()
        if inv.windowCount > before {
            inv.closeFrontWindow()
        }
        inv.waitFor("visualizer window closed") { inv.windowCount == before }
    }

    // MARK: Immersive Mode (ADR-089; last too: it animates a space transition)

    /// Enter and exit through the menu, which also covers the item's flipped
    /// title. No other journey invokes it: the toolbar surface skips its
    /// button for the same full-screen reason.
    private func immersiveModeItems(_ inv: MenuInvoker) {
        self.run(["View", "Enter Immersive Mode"], inv)
        inv.waitFor("immersive window") { inv.element("immersive").exists }
        inv.settle(1.5)
        self.run(["View", "Exit Immersive Mode"], inv)
        inv.waitFor("immersive window closed", timeout: 10) { !inv.element("immersive").exists }
    }

    // MARK: Coverage bookkeeping

    /// Invokes `path` and records it for the completeness assertion.
    /// Returns the title of the invoked item, the last element of `path`.
    @discardableResult
    func run(_ path: [String], _ inv: MenuInvoker) -> String {
        inv.invoke(path)
        // `invoke` accepts only a path of two or three titles, so there is
        // always a last one; an empty path fails the test here.
        guard let title = path.last else {
            XCTFail("empty menu path")
            return ""
        }
        self.covered.insert(title)
        return title
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
