import AppKit
import XCTest

// MARK: - MenuInvoker

/// Clicks menu items by manifest path and owns the shared postcondition
/// helpers for the phase 30 invocation pass.
@MainActor
struct MenuInvoker {
    let app: XCUIApplication

    // MARK: Invocation

    /// Invokes a menu item by path: `[menu, item]` or `[menu, submenu,
    /// item]` (one submenu level is all the menu bar has). Item queries
    /// are scoped to the opened menu: SwiftUI auto-generates same-titled
    /// open-window items in the Window menu ("About Bòcan"), so an
    /// app-wide query is ambiguous.
    func invoke(_ path: [String]) {
        precondition((2 ... 3).contains(path.count), "unsupported menu path \(path)")
        let barItem = self.app.menuBars.firstMatch.menuBarItems[path[0]]
        barItem.click()
        self.settle(0.15)
        if path.count == 2 {
            barItem.menuItems[path[1]].click()
        } else {
            barItem.menuItems[path[1]].hover()
            self.settle(0.3)
            barItem.menuItems[path[2]].click()
        }
        self.settle(0.2)
    }

    /// True when `menu` currently contains an item titled `title` (used
    /// for Show/Hide title-flip postconditions). Leaves the menu closed.
    func menuHasItem(_ menu: String, _ title: String) -> Bool {
        let barItem = self.app.menuBars.firstMatch.menuBarItems[menu]
        barItem.click()
        self.settle(0.15)
        let exists = barItem.menuItems[title].exists
        self.app.typeKey(.escape, modifierFlags: [])
        self.settle(0.1)
        return exists
    }

    // MARK: Postcondition helpers

    /// Polls `condition` until it holds or `timeout` elapses. On timeout,
    /// writes a screenshot to the runner's tmp (readable from outside the
    /// sandbox) so the failure state can be inspected.
    @discardableResult
    func waitFor(
        _ what: String,
        timeout: TimeInterval = 8,
        condition: () throws -> Bool
    ) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return true }
            self.settle(0.25)
        }
        let shot = XCUIScreen.main.screenshot()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("waitfail-\(UInt(Date().timeIntervalSince1970)).png")
        try? shot.pngRepresentation.write(to: url)
        print("WAITFAIL screenshot: \(url.path)")
        XCTFail("timed out waiting for \(what)")
        return false
    }

    var windowCount: Int {
        self.app.windows.count
    }

    /// Closes the frontmost window with ⌘W.
    func closeFrontWindow() {
        self.app.typeKey("w", modifierFlags: .command)
        self.settle(0.3)
    }

    /// Dismisses a sheet or panel with Escape.
    func pressEscape() {
        self.app.typeKey(.escape, modifierFlags: [])
        self.settle(0.3)
    }

    /// Dismisses the frontmost sheet: Escape first, then the standard
    /// cancel buttons for sheets whose fields consume Escape.
    func dismissSheet() {
        let sheet = self.app.sheets.firstMatch
        guard sheet.exists else { return }
        self.pressEscape()
        if sheet.exists {
            for name in ["Cancel", "Close", "Done"] where sheet.buttons[name].exists {
                sheet.buttons[name].click()
                break
            }
            self.settle(0.3)
        }
    }

    /// The element carrying `identifier`, whatever its type.
    func element(_ identifier: String) -> XCUIElement {
        self.app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// `identifier`'s current label, or nil if no matching element exists
    /// yet. Guards on `.exists` first: touching `.label`/`.value` on a
    /// zero-match query hard-fails the test via XCTest's own snapshot
    /// resolution rather than returning something falsy (found empirically,
    /// phase 33/34) — this is the safe way to poll for text that appears
    /// asynchronously.
    func label(_ identifier: String) -> String? {
        let element = self.element(identifier)
        return element.exists ? element.label : nil
    }

    /// `identifier`'s current value as a string, or nil if no matching
    /// element exists yet (see `label(_:)`). Elements carrying
    /// `.accessibilityAddTraits(.updatesFrequently)` — e.g. the now-playing
    /// strip's title — expose their live text as `.value`, not `.label`,
    /// regardless of which SwiftUI modifier set it (found empirically,
    /// phase 34, via an AX tree dump).
    func value(_ identifier: String) -> String? {
        let element = self.element(identifier)
        guard element.exists, let value = element.value else { return nil }
        return String(describing: value)
    }

    /// True when any element in the main window's tree carries `text` in
    /// its label, title, or value (snapshot walk: one AX round trip).
    func mainWindowContains(_ text: String) -> Bool {
        guard let snapshot = try? self.app.windows.firstMatch.snapshot() else { return false }
        return Self.contains(snapshot, text: text)
    }

    private static func contains(_ node: XCUIElementSnapshot, text: String) -> Bool {
        if node.label.contains(text) || node.title.contains(text) { return true }
        if let value = node.value as? String, value.contains(text) { return true }
        return node.children.contains { self.contains($0, text: text) }
    }

    /// How many of the two seeded fixture titles are currently visible as
    /// content rows. During the ratings section nothing is playing (so the
    /// strip shows no title) and the sidebar holds no track titles, making
    /// this a reliable stand-in for "rows in the visible list" that does
    /// not depend on the AppKit table's ambiguous identifier.
    func visibleFixtureTitleCount() -> Int {
        ["E2E Tone One", "E2E Tone Two"].count { self.app.staticTexts[$0].firstMatch.exists }
    }

    /// Rows currently in the library track table.
    func trackTableRowCount() -> Int {
        let table = self.app.tables["tracksTable"]
        guard table.exists, let snapshot = try? table.snapshot() else { return 0 }
        return Self.rows(in: snapshot)
    }

    private static func rows(in node: XCUIElementSnapshot) -> Int {
        let own = node.elementType == .tableRow ? 1 : 0
        return own + node.children.map { self.rows(in: $0) }.reduce(0, +)
    }

    /// Selected rows in the library track table.
    func selectedTrackRowCount() -> Int {
        let table = self.app.tables["tracksTable"]
        guard table.exists, let snapshot = try? table.snapshot() else { return 0 }
        return Self.selectedRows(in: snapshot)
    }

    private static func selectedRows(in node: XCUIElementSnapshot) -> Int {
        let own = node.elementType == .tableRow && node.isSelected ? 1 : 0
        return own + node.children.map { self.selectedRows(in: $0) }.reduce(0, +)
    }

    /// Fixed sidebar-row title to its stable A11y identifier. Phase 30
    /// attached these; before that the tag-selected List rows were absent
    /// from the AX tree entirely (a real VoiceOver defect). Playlist rows
    /// are addressed by their "Playlist: <name>" accessibility label.
    private static let sidebarIdentifiers: [String: String] = [
        "Songs": "sidebar.songs", "Albums": "sidebar.albums",
        "Artists": "sidebar.artists", "Genres": "sidebar.genres",
        "Composers": "sidebar.composers", "Recently Added": "sidebar.recentlyAdded",
        "Recently Played": "sidebar.recentlyPlayed", "Most Played": "sidebar.mostPlayed",
        "Up Next": "sidebar.upNext", "Radio": "sidebar.radio",
    ]

    /// Clicks a sidebar destination row and waits for the switch. Fixed
    /// library rows resolve by their stable identifier; playlist rows by
    /// their "Playlist: <name>" label. Retries because the query does not
    /// auto-wait and a destination change can briefly empty the tree. Does
    /// not gate on isHittable: a List row reports not-hittable (the cell is
    /// the hit target) yet clicking it still selects.
    func selectSidebar(_ title: String) {
        let predicate = if let identifier = Self.sidebarIdentifiers[title] {
            NSPredicate(format: "identifier == %@", identifier)
        } else {
            NSPredicate(format: "label == %@", "Playlist: \(title)")
        }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let matches = self.app.descendants(matching: .any).matching(predicate)
            // The label/identifier is inherited by the row's icon Image
            // sub-element too; take the widest match (the full-width row)
            // and tap its centre coordinate, which selects even when the
            // element reports not-hittable.
            if let row = Self.widest(of: matches) {
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                self.settle(0.5)
                return
            }
            self.settle(0.25)
        }
        XCTFail("sidebar row \"\(title)\" never appeared")
    }

    private static func widest(of query: XCUIElementQuery) -> XCUIElement? {
        let count = query.count
        guard count > 0 else { return nil }
        var target = query.firstMatch
        var widest = -1.0
        for index in 0 ..< count {
            let candidate = query.element(boundBy: index)
            let width = Double(candidate.frame.width)
            if width > widest {
                widest = width
                target = candidate
            }
        }
        return target
    }

    func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Types `text` into `field` via the system pasteboard and Cmd-V rather
    /// than `XCUIElement.typeText`, which silently drops certain characters
    /// — a colon in a `http://127.0.0.1:PORT/...` loopback URL, found
    /// empirically (phase 34) — during keyboard-event synthesis. The
    /// pasteboard is genuine OS-level shared state, so writing from the
    /// runner process here and pasting in the app process works correctly.
    /// Selects all first so this also replaces any prefilled text.
    func pasteText(_ text: String, into field: XCUIElement) {
        field.click()
        self.app.typeKey("a", modifierFlags: .command)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        self.app.typeKey("v", modifierFlags: .command)
    }
}
