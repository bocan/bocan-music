import XCTest

// MARK: - ObservedMenuItem

/// One menu item as the accessibility tree reports it (phase 30).
struct ObservedMenuItem {
    let title: String
    let enabled: Bool
    /// Submenu items, populated by hovering the parent during the crawl.
    var children: [ObservedMenuItem]

    /// Multi-line dump used in failure messages so a structural mismatch
    /// shows the whole observed tree, not just the first difference.
    func dump(indent: String = "  ") -> [String] {
        var lines = ["\(indent)\(self.enabled ? "" : "(disabled) ")\(self.title)"]
        for child in self.children {
            lines += child.dump(indent: indent + "  ")
        }
        return lines
    }
}

// MARK: - ObservedMenu

/// One opened top-level menu and its items, separators omitted.
struct ObservedMenu {
    let title: String
    var items: [ObservedMenuItem]

    func dump() -> [String] {
        ["\(self.title)"] + self.items.flatMap { $0.dump() }
    }
}

// MARK: - MenuBarCrawler

/// Opens every top-level menu in turn and captures the item tree via one
/// accessibility snapshot per menu (fast, phase 29 pattern). Submenu
/// parents are hovered so their children materialize; enablement is read
/// with the menu open, after a short settle, because AppKit validates menu
/// items lazily (spec gotcha).
@MainActor
struct MenuBarCrawler {
    let app: XCUIApplication

    /// Menu bar item titles never opened (Apple owns the whole menu).
    static let skippedMenuBarItems: Set = ["Apple"]

    /// Crawls every non-skipped top-level menu. The crawl leaves all menus
    /// closed on return.
    func crawlMenuBar() throws -> [ObservedMenu] {
        let bar = self.app.menuBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "menu bar never appeared")
        var menus: [ObservedMenu] = []
        let count = bar.children(matching: .menuBarItem).count
        for index in 0 ..< count {
            let barItem = bar.children(matching: .menuBarItem).element(boundBy: index)
            let title = self.bestTitle(of: barItem)
            if Self.skippedMenuBarItems.contains(title) { continue }
            try menus.append(self.crawl(menuBarItem: barItem, title: title))
        }
        return menus
    }

    /// Opens one top-level menu, snapshots it, hovers submenu parents to
    /// materialize their children, and closes it again.
    private func crawl(menuBarItem: XCUIElement, title: String) throws -> ObservedMenu {
        menuBarItem.click()
        self.settle()
        var menu = try ObservedMenu(
            title: title,
            items: self.items(underOpenedElement: menuBarItem.snapshot())
        )
        for (index, item) in menu.items.enumerated() where item.children.isEmpty {
            // A submenu parent's children only materialize on hover; detect
            // parents by asking the live element for a nested menu.
            let live = menuBarItem.menuItems[item.title]
            guard live.exists, live.menus.firstMatch.exists else { continue }
            live.hover()
            self.settle()
            menu.items[index].children = try self.items(underOpenedElement: live.snapshot())
        }
        self.closeMenus()
        return menu
    }

    /// Extracts the item list from a snapshot of an element whose menu is
    /// open (a menu bar item, or a hovered submenu parent).
    private func items(underOpenedElement snapshot: XCUIElementSnapshot) -> [ObservedMenuItem] {
        guard let menu = Self.firstDescendant(of: snapshot, ofType: .menu) else { return [] }
        return menu.children.compactMap { child in
            guard child.elementType == .menuItem else { return nil }
            let title = child.title.isEmpty ? child.label : child.title
            guard !title.isEmpty else { return nil } // separator
            return ObservedMenuItem(title: title, enabled: child.isEnabled, children: [])
        }
    }

    private static func firstDescendant(
        of node: XCUIElementSnapshot,
        ofType type: XCUIElement.ElementType
    ) -> XCUIElementSnapshot? {
        if node.elementType == type { return node }
        for child in node.children {
            if let found = self.firstDescendant(of: child, ofType: type) { return found }
        }
        return nil
    }

    private func bestTitle(of element: XCUIElement) -> String {
        let title = element.title
        return title.isEmpty ? element.label : title
    }

    /// Menu enablement updates lazily; let AppKit validate before reading.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    /// Closes any open menu (twice, in case a submenu is open).
    func closeMenus() {
        self.app.typeKey(.escape, modifierFlags: [])
        self.app.typeKey(.escape, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
}
