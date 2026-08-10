import XCTest

// MARK: - MenuCrawlTests

/// Phase 30 structural crawl: the live menu bar must match `MenuManifest`
/// bidirectionally. A manifest item missing from the bar fails ("a menu
/// item quietly vanished"); an observed item the manifest does not claim
/// fails ("a menu item shipped unreviewed"); order must match; submenus
/// recurse. System-owned noise is tolerated only where the manifest says
/// so (`sys` entries, `ignoreChildren`, `crawlContents: false`). The
/// negative-test verification note lives in the manifest header.
@MainActor
final class MenuCrawlTests: XCTestCase {
    private var session: E2ESession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    func testMenuBarMatchesManifest() throws {
        let app = self.session.launch(arguments: MenuManifest.pinnedDefaults)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60), "fixture scan never produced rows")
        app.activate()
        let observed = try MenuBarCrawler(app: app).crawlMenuBar()

        var failures: [String] = []
        self.compareMenuBar(observed: observed, failures: &failures)
        if !failures.isEmpty {
            let tree = observed.flatMap { $0.dump() }.joined(separator: "\n")
            XCTFail(
                """
                \(failures.count) structural mismatch(es):
                \(failures.map { "  - \($0)" }.joined(separator: "\n"))
                Observed tree:
                \(tree)
                """
            )
        }
    }

    // MARK: Comparison

    private func compareMenuBar(observed: [ObservedMenu], failures: inout [String]) {
        let expectedTitles = MenuManifest.menus.map(\.title)
        let observedTitles = observed.map(\.title)
        guard expectedTitles == observedTitles else {
            failures.append(
                "top-level menus \(observedTitles) != manifest \(expectedTitles)"
            )
            return
        }
        for (menu, spec) in zip(observed, MenuManifest.menus) where spec.crawlContents {
            self.compare(
                observed: menu.items,
                specs: spec.items,
                path: menu.title,
                failures: &failures
            )
        }
    }

    private func compare(
        observed: [ObservedMenuItem],
        specs: [MenuItemSpec],
        path: String,
        failures: inout [String]
    ) {
        var index = 0
        for spec in specs {
            if index < observed.count, spec.titles.contains(observed[index].title) {
                let item = observed[index]
                index += 1
                if spec.ignoreChildren { continue }
                if !spec.submenu.isEmpty || !item.children.isEmpty {
                    self.compare(
                        observed: item.children,
                        specs: spec.submenu,
                        path: "\(path) ▸ \(item.title)",
                        failures: &failures
                    )
                }
            } else if spec.conditional != nil {
                continue // absence is legitimate; presence matched above
            } else {
                let next = index < observed.count ? observed[index].title : "(end of menu)"
                failures.append(
                    "\(path): expected \"\(spec.canonicalTitle)\", found \"\(next)\""
                )
                return // the sequences have desynced; the dump tells the rest
            }
        }
        for extra in observed[index...] {
            failures.append("\(path): item \"\(extra.title)\" is not in the manifest")
        }
    }
}
