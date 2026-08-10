import XCTest

// MARK: - ShortcutParityTests

/// Phase 30 shortcut parity: one source-convention test family comparing
/// four representations of every shortcut so they can never drift apart
/// silently again (the help book shipped three wrong shortcuts for
/// months): the manifest, `KeyBindings.swift`, the `BocanCommands*.swift`
/// menu declarations, and the help book (its Keyboard Shortcuts table row
/// by row, plus every shortcut token in its prose). Runs without
/// launching the app; sources are read relative to the repo root.
final class ShortcutParityTests: XCTestCase {
    /// Manifest items that carry a shortcut (submenus flattened).
    private var shortcutItems: [MenuItemSpec] {
        MenuManifest.allItems.filter { $0.shortcut != nil }
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
                item.shortcut, bound,
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
                    item.binding, name,
                    "\(item.canonicalTitle): source routes through KeyBindings.\(name), manifest says \(item.binding ?? "inline")"
                )
                XCTAssertEqual(item.shortcut, bindings[name], item.canonicalTitle)

            case let .inline(shortcut):
                XCTAssertNil(
                    item.binding,
                    "\(item.canonicalTitle): manifest expects KeyBindings routing, source is inline"
                )
                XCTAssertEqual(
                    item.shortcut, shortcut,
                    "\(item.canonicalTitle): manifest says \(item.shortcut.map(String.init(describing:)) ?? "none"), source says \(shortcut)"
                )
            }
        }

        for item in self.shortcutItems where !item.system {
            XCTAssertTrue(
                claimedTitles.contains(item.canonicalTitle),
                "\(item.canonicalTitle): manifest declares \(item.shortcut!) but no menu source site carries it"
            )
        }
    }

    /// Manifest ▸ help book table, both directions: every row in the
    /// Keyboard Shortcuts table belongs to exactly one manifest item and
    /// shows its exact shortcut; every manifest `helpBookRow` exists.
    func testHelpBookTableMatchesManifest() throws {
        let rows = try MenuSourceParsing.helpBookTableRows()
        XCTAssertFalse(rows.isEmpty, "help book shortcut table parsed to nothing")
        let byRow = Dictionary(
            uniqueKeysWithValues: MenuManifest.allItems
                .compactMap { item in item.helpBookRow.map { ($0, item) } }
        )

        for (action, display) in rows {
            guard let item = byRow[action] else {
                XCTFail("help book row \"\(action)\" is not claimed by any manifest item")
                continue
            }
            XCTAssertEqual(
                MenuShortcut.fromDisplay(display), item.shortcut,
                "help book says \(action) = \(display), manifest says \(item.shortcut.map(String.init(describing:)) ?? "none")"
            )
        }

        let tableActions = Set(rows.map(\.action))
        for (action, item) in byRow {
            XCTAssertTrue(
                tableActions.contains(action),
                "\(item.canonicalTitle): manifest expects help book row \"\(action)\", table has none"
            )
        }
    }

    /// Every shortcut-looking token anywhere in the help book (prose
    /// included) must be a shortcut some manifest item actually has, so a
    /// stale "⌘⇧X" in running text fails here.
    func testHelpBookProseTokensMatchManifest() throws {
        let tokens = try MenuSourceParsing.helpBookShortcutTokens()
        XCTAssertFalse(tokens.isEmpty, "help book parsed to no shortcut tokens")
        let known = Set(self.shortcutItems.compactMap(\.shortcut))
        for token in tokens {
            guard let parsed = MenuShortcut.fromDisplay(token) else {
                XCTFail("help book token \"\(token)\" does not parse as a shortcut")
                continue
            }
            XCTAssertTrue(
                known.contains(parsed),
                "help book mentions \(token) but no menu item has that shortcut"
            )
        }
    }
}
