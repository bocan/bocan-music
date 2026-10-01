import XCTest

// MARK: - ShortcutParityTests

/// Phase 30 shortcut parity: one source-convention test family comparing
/// four representations of every shortcut so they can never drift apart
/// silently again (the help text shipped three wrong shortcuts for
/// months): the manifest, `KeyBindings.swift`, the `BocanCommands*.swift`
/// menu declarations, and the in-app Help window (its Keyboard Shortcuts table
/// row by row, plus every shortcut token in its prose). Runs without
/// launching the app; sources are read relative to the repo root.
final class ShortcutParityTests: XCTestCase {
    /// Manifest items that carry a shortcut (submenus flattened).
    private var shortcutItems: [MenuItemSpec] {
        MenuManifest.allItems.filter { $0.shortcut != nil }
    }

    /// Every `key:` in the manifest must parse into a shortcut. The manifest
    /// keeps the text of one that does not, so a typing error fails here
    /// instead of stopping the whole test process when the table loads.
    func testManifestKeysParse() {
        for item in MenuManifest.allItems {
            XCTAssertNil(
                item.unparsedKey,
                "\(item.canonicalTitle): manifest key \(item.unparsedKey ?? "") is not a shortcut"
            )
        }
    }

    /// Manifest ▸ KeyBindings: every item that declares a binding name
    /// must match the parsed `KeyBindings` constant, and the constant must
    /// exist.
    func testManifestMatchesKeyBindings() throws {
        let bindings = try MenuSourceParsing.keyBindings()
        XCTAssertFalse(bindings.isEmpty, "KeyBindings.swift parsed to nothing")
        for item in MenuManifest.allItems {
            guard let name = item.binding else { continue }
            guard let bound = bindings[name] else {
                XCTFail("\(item.canonicalTitle): KeyBindings.\(name) does not exist")
                continue
            }
            XCTAssertEqual(
                item.shortcut,
                bound,
                "\(item.canonicalTitle): manifest says \(item.shortcut.map(String.init(describing:)) ?? "none"), KeyBindings.\(name) is \(bound)"
            )
        }
    }

    /// Manifest ▸ menu source, both directions: every shortcut-carrying
    /// `Button` in `BocanCommands*.swift` must be claimed by a manifest
    /// item with the same shortcut (and the same `KeyBindings` routing),
    /// and every manifest shortcut must exist in source.
    func testMenuSourceMatchesManifest() throws {
        let sites = try MenuSourceParsing.commandShortcutSites()
        XCTAssertFalse(sites.isEmpty, "BocanCommands parsed to no shortcut sites")
        let bindings = try MenuSourceParsing.keyBindings()

        var claimedTitles: Set<String> = []
        for site in sites {
            let matches = self.shortcutItems.filter {
                !Set($0.titles).isDisjoint(with: site.titles)
            }
            guard let item = matches.first, matches.count == 1 else {
                XCTFail(
                    "menu item \(site.titles) with a shortcut has \(matches.count) manifest claims"
                )
                continue
            }
            claimedTitles.insert(item.canonicalTitle)
            switch site.shortcut {
            case let .binding(name):
                XCTAssertEqual(
                    item.binding,
                    name,
                    "\(item.canonicalTitle): source routes through KeyBindings.\(name), manifest says \(item.binding ?? "inline")"
                )
                XCTAssertEqual(item.shortcut, bindings[name], item.canonicalTitle)

            case let .inline(shortcut):
                XCTAssertNil(
                    item.binding,
                    "\(item.canonicalTitle): manifest expects KeyBindings routing, source is inline"
                )
                XCTAssertEqual(
                    item.shortcut,
                    shortcut,
                    "\(item.canonicalTitle): manifest says \(item.shortcut.map(String.init(describing:)) ?? "none"), source says \(shortcut)"
                )
            }
        }

        for item in self.shortcutItems where !item.system {
            let declared = item.shortcut.map(String.init(describing:)) ?? "none"
            XCTAssertTrue(
                claimedTitles.contains(item.canonicalTitle),
                "\(item.canonicalTitle): manifest declares \(declared) but no menu source site carries it"
            )
        }
    }

    /// Manifest ▸ Help window table, both directions: every row in the
    /// Keyboard Shortcuts table belongs to exactly one manifest item and
    /// shows its exact shortcut; every manifest `helpRow` exists.
    func testHelpTableMatchesManifest() throws {
        let rows = try MenuSourceParsing.helpTableRows()
        XCTAssertFalse(rows.isEmpty, "help shortcut table parsed to nothing")
        let byRow = Dictionary(
            uniqueKeysWithValues: MenuManifest.allItems
                .compactMap { item in item.helpRow.map { ($0, item) } }
        )

        let helpOnly = Dictionary(uniqueKeysWithValues: MenuManifest.helpOnlyRows)
        for (action, display) in rows {
            if let literal = helpOnly[action] {
                XCTAssertEqual(display, literal, "help-only row \(action)")
                continue
            }
            guard let item = byRow[action] else {
                XCTFail("help row \"\(action)\" is not claimed by any manifest item")
                continue
            }
            // An aggregated row ("⌘1–⌘5") declares its literal display text;
            // a normal row must parse to the item's exact shortcut.
            if let literal = item.helpDisplay {
                XCTAssertEqual(display, literal, "help row \(action)")
                continue
            }
            XCTAssertEqual(
                MenuShortcut.fromDisplay(display),
                item.shortcut,
                "help says \(action) = \(display), manifest says \(item.shortcut.map(String.init(describing:)) ?? "none")"
            )
        }

        let tableActions = Set(rows.map(\.action))
        for (action, item) in byRow {
            XCTAssertTrue(
                tableActions.contains(action),
                "\(item.canonicalTitle): manifest expects help row \"\(action)\", table has none"
            )
        }
        for (action, _) in MenuManifest.helpOnlyRows {
            XCTAssertTrue(
                tableActions.contains(action),
                "manifest expects help-only row \"\(action)\", table has none"
            )
        }
    }

    /// Every shortcut-looking token anywhere in the Help window's text (prose
    /// included) must be a shortcut some manifest item actually has, or one
    /// the manifest lists as bound by a view, so a stale "⌘⇧X" in running
    /// text fails here.
    func testHelpProseTokensMatchManifest() throws {
        let tokens = try MenuSourceParsing.helpShortcutTokens()
        XCTAssertFalse(tokens.isEmpty, "help text parsed to no shortcut tokens")
        let known = Set(self.shortcutItems.compactMap(\.shortcut))
            .union(MenuManifest.viewBoundShortcuts.compactMap(MenuShortcut.fromDisplay))
        for token in tokens {
            guard let parsed = MenuShortcut.fromDisplay(token) else {
                XCTFail("help token \"\(token)\" does not parse as a shortcut")
                continue
            }
            XCTAssertTrue(
                known.contains(parsed),
                "help mentions \(token) but no menu item or view-bound shortcut matches it"
            )
        }
    }
}
