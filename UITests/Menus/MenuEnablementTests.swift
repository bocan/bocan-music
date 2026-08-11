import XCTest

// MARK: - MenuEnablementTests

/// Phase 30 enablement matrix: for each scripted app state, every menu
/// item with an expectation in `MenuManifest` must report exactly that
/// enablement, read with the menu open (AppKit validates lazily; the
/// assert re-crawls with a settle-and-retry loop instead of trusting one
/// read). States are reached through the UI, never by writing defaults.
///
/// The ⌘A regression (#379) is a permanent row here: with the toolbar
/// search field focused, Select All must select the field's text and
/// leave the track-list selection untouched.
@MainActor
final class MenuEnablementTests: XCTestCase {
    private var session: E2ESession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    // MARK: States 1-4: fresh, selected, playing, search-focused

    func testEnablementMatrix() throws {
        let app = self.session.launch(arguments: MenuManifest.matrixDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        let crawler = MenuBarCrawler(app: app)

        // The fixture scans settle within a couple of seconds of the rows
        // appearing; the assert's own retry loop absorbs that window. (The
        // scan banner is no wait signal: its summary auto-dismisses after
        // 3 seconds, long before waitForTrackRows returns.)
        try self.assertEnablement(.freshLaunch, crawler: crawler)

        app.firstTrackRow.click()
        try self.assertEnablement(.trackSelected, crawler: crawler)

        app.firstTrackRow.doubleClick()
        XCTAssertTrue(app.waitUntilPlaying(timeout: 15), "double-click never started playback")
        try self.assertEnablement(.trackPlaying, crawler: crawler)

        try self.assertSelectAllRoutesToSearchField(app: app)
    }

    // MARK: State 5: seeded radio queue current, not playing

    func testRadioCurrentEnablement() throws {
        let listener = try StallingListener()
        let app = self.session.launch(
            environment: ["BOCAN_E2E_SEED_RADIO_URL": listener.url.absoluteString],
            arguments: MenuManifest.matrixDefaults
        )
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        try self.assertEnablement(.radioCurrent, crawler: MenuBarCrawler(app: app))
    }

    // MARK: The ⌘A row (#379)

    private func assertSelectAllRoutesToSearchField(app: XCUIApplication) throws {
        app.typeKey("f", modifierFlags: .command)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F never focused the search field")
        app.typeText("tone")
        self.settle() // search filtering debounce
        let selectedBefore = try self.selectedTrackRowCount(app: app)

        app.typeKey("a", modifierFlags: .command)
        self.settle()
        XCTAssertEqual(
            try self.selectedTrackRowCount(app: app), selectedBefore,
            "⌘A in the search field must not change the track selection (#379)"
        )
        app.typeText("x")
        XCTAssertEqual(
            field.value as? String, "x",
            "⌘A must select the search field's text so typing replaces it (#379)"
        )
    }

    private func selectedTrackRowCount(app: XCUIApplication) throws -> Int {
        let table = app.tables["tracksTable"]
        guard table.exists else { return 0 }
        return try Self.selectedRows(in: table.snapshot())
    }

    private static func selectedRows(in node: XCUIElementSnapshot) -> Int {
        let own = node.elementType == .tableRow && node.isSelected ? 1 : 0
        return own + node.children.map(Self.selectedRows(in:)).reduce(0, +)
    }

    // MARK: Matrix interpreter

    /// Re-crawls every menu that carries expectations for `state` until
    /// all of them match or the retry budget runs out (menu validation is
    /// lazy, and the fresh-launch state additionally waits out the scan).
    private func assertEnablement(_ state: MenuState, crawler: MenuBarCrawler) throws {
        let interesting: [(menu: String, specs: [MenuItemSpec])] = MenuManifest.menus
            .compactMap { menu in
                let specs = Self.flatten(menu.items).filter { $0.enablement[state] != nil }
                return specs.isEmpty ? nil : (menu.title, specs)
            }
        var mismatches: [String] = []
        for attempt in 1 ... 4 {
            mismatches = []
            for (menuTitle, specs) in interesting {
                let observed = try crawler.crawl(menuTitled: menuTitle)
                for spec in specs {
                    let expected = spec.enablement[state]!
                    guard let item = Self.find(spec, in: observed.items) else {
                        mismatches.append(
                            "[\(state.rawValue)] \(menuTitle) ▸ \(spec.canonicalTitle): not found"
                        )
                        continue
                    }
                    if item.enabled != expected {
                        mismatches.append(
                            "[\(state.rawValue)] \(menuTitle) ▸ \(spec.canonicalTitle): expected \(expected ? "enabled" : "disabled"), observed \(item.enabled ? "enabled" : "disabled")"
                        )
                    }
                }
            }
            if mismatches.isEmpty { return }
            if attempt < 4 { self.settle(1.0) }
        }
        XCTFail(
            """
            \(mismatches.count) enablement mismatch(es):
            \(mismatches.map { "  - \($0)" }.joined(separator: "\n"))
            """
        )
    }

    private static func flatten(_ specs: [MenuItemSpec]) -> [MenuItemSpec] {
        specs.flatMap { [$0] + self.flatten($0.submenu) }
    }

    private static func find(
        _ spec: MenuItemSpec,
        in items: [ObservedMenuItem]
    ) -> ObservedMenuItem? {
        for item in items {
            if spec.titles.contains(item.title) { return item }
            if let nested = self.find(spec, in: item.children) { return nested }
        }
        return nil
    }

    private func settle(_ seconds: TimeInterval = 0.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
