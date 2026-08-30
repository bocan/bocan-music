import XCTest

// MARK: - IdentifierAuditTests

/// Phase 29: walks every fixture-reachable surface and fails on any enabled
/// interactive control that ships without an accessibility identifier, so
/// the crawling phases (30-32) can find every control they want to click.
///
/// The walk snapshots each window once (`XCUIElement.snapshot()`) and
/// recurses in-process, which is orders of magnitude faster than resolving
/// per-element XCUITest queries.
///
/// AppKit-backed tables and outlines are skipped as whole subtrees here:
/// their sort headers are AppKit-owned, and their per-row controls are
/// hover-revealed and audited by the row-level pass (spec gotcha; see
/// phase-29 plan item 2).
///
/// Negative test verified manually on 2026-08-11: stripping the identifier
/// from the toolbar Back button produced exactly one violation
/// (`[Albums] button label="Back" has no identifier`) and a failing audit.
@MainActor
final class IdentifierAuditTests: XCTestCase {
    private var session: E2ESession!

    override func setUp() async throws {
        continueAfterFailure = false
        self.session = E2ESession.make(named: self.name.sanitizedTestName)
    }

    // MARK: Allowlist

    /// Controls that legitimately ship without an app identifier. One entry
    /// per line, each with a reason. Keep this list small enough to read in
    /// one sitting.
    private static let allowlist: Set<Allowance> = [
        // AppKit window chrome: the app cannot attach identifiers to these.
        Allowance(.button, "Close"),
        Allowance(.button, "Minimize"),
        Allowance(.button, "Zoom"),
        // AppKit sidebar/split-view chrome.
        Allowance(.button, "Toggle Sidebar"),
        // SwiftUI's automatic NavigationSplitView sidebar toggle; no
        // modifier reaches it.
        Allowance(.button, "Hide Sidebar"),
        Allowance(.button, "Show Sidebar"),
        // The .searchable toolbar item; SwiftUI owns the control and offers
        // no identifier hook.
        Allowance(.button, "Search"),
    ]

    /// Label prefixes of SwiftUI-generated controls (sidebar Section
    /// disclosure buttons: "Collapse Recents", "Expand Queue", ...); no
    /// modifier reaches them.
    private static let allowedLabelPrefixes = ["Collapse ", "Expand "]

    struct Allowance: Hashable {
        let type: XCUIElement.ElementType
        let label: String

        init(_ type: XCUIElement.ElementType, _ label: String) {
            self.type = type
            self.label = label
        }
    }

    /// Element types the audit inspects: the phase 29 spec's list plus
    /// `.switch` and `.radioButton`, which SwiftUI toggles and pickers
    /// produce on macOS.
    private static let auditedTypes: Set<XCUIElement.ElementType> = [
        .button, .checkBox, .popUpButton, .slider, .menuButton, .textField,
        .switch, .radioButton,
    ]

    /// AppKit library tables, skipped wholesale by identifier: their sort
    /// headers are AppKit-owned and their per-row controls are audited via
    /// the row-level pass. SwiftUI Lists and Forms also present as
    /// tables/outlines, so the skip must be identifier-scoped, never
    /// type-wide, or whole Settings panes vanish from the audit.
    private static let skippedTableIdentifiers: Set = [
        "tracksTable", "subsonicSongsTable",
    ]

    // MARK: The audit walk

    private struct Violation: Hashable, CustomStringConvertible {
        let surface: String
        let type: String
        let label: String
        /// Rounded frame, recorded only for empty-label controls so they
        /// can be located on screen (an empty label names nothing).
        let frame: String

        var description: String {
            let location = self.frame.isEmpty ? "" : " at \(self.frame)"
            return "[\(self.surface)] \(self.type) label=\"\(self.label)\"\(location) has no identifier"
        }
    }

    private func audit(window: XCUIElement, surface: String) throws -> Set<Violation> {
        let snapshot = try window.snapshot()
        var violations: Set<Violation> = []
        Self.walk(snapshot, surface: surface, into: &violations)
        return violations
    }

    private static func walk(
        _ node: XCUIElementSnapshot,
        surface: String,
        into violations: inout Set<Violation>,
        insideIdentifiedControl: Bool = false
    ) {
        if node.elementType == .table || node.elementType == .outline,
           self.skippedTableIdentifiers.contains(node.identifier) { return }
        // Segmented pickers expose their segments as radio buttons; the
        // segments are addressed through the identified picker plus their
        // label, so they need no identifiers of their own.
        let segmentOfIdentifiedPicker = node.elementType == .radioButton && insideIdentifiedControl
        if self.auditedTypes.contains(node.elementType),
           node.isEnabled,
           node.identifier.isEmpty,
           !segmentOfIdentifiedPicker,
           !self.allowlist.contains(Allowance(node.elementType, node.label)),
           !self.allowedLabelPrefixes.contains(where: { node.label.hasPrefix($0) }) {
            let frame = node.label.isEmpty
                ? "(\(Int(node.frame.origin.x)),\(Int(node.frame.origin.y)) \(Int(node.frame.width))x\(Int(node.frame.height)))"
                : ""
            violations.insert(Violation(
                surface: surface,
                type: self.typeName(node.elementType),
                label: node.label,
                frame: frame
            ))
        }
        let identified = insideIdentifiedControl || !node.identifier.isEmpty
        for child in node.children {
            self.walk(child, surface: surface, into: &violations, insideIdentifiedControl: identified)
        }
    }

    private static func typeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: "button"
        case .checkBox: "checkBox"
        case .popUpButton: "popUpButton"
        case .slider: "slider"
        case .menuButton: "menuButton"
        case .textField: "textField"
        case .switch: "switch"
        case .radioButton: "radioButton"
        default: "type#\(type.rawValue)"
        }
    }

    // MARK: Main window destinations

    /// Every sidebar destination reachable in fixture mode, audited in one
    /// launch. Violations across surfaces are deduplicated by control, so
    /// shared chrome (the transport strip) reports once.
    func testMainWindowSurfacesCarryIdentifiers() throws {
        let app = self.session.launch()
        defer { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        XCTAssertTrue(
            app.waitForTrackRows(timeout: 60),
            "Fixture library must scan in before auditing surfaces"
        )

        var violations = try self.audit(window: window, surface: "launch")

        let destinations = [
            "Songs", "Albums", "Artists", "Genres", "Composers", "Podcasts",
            "Radio", "Recently Added", "Recently Played", "Most Played",
            "Up Next",
        ]
        for destination in destinations {
            let row = app.staticTexts[destination].firstMatch
            guard row.waitForExistence(timeout: 10) else {
                XCTFail("Sidebar destination \"\(destination)\" not found")
                continue
            }
            row.click()
            Thread.sleep(forTimeInterval: 0.5)
            try violations.formUnion(self.audit(window: window, surface: destination))
        }

        let deduplicated = Self.dedupeAcrossSurfaces(violations)
        XCTAssertTrue(
            deduplicated.isEmpty,
            "Unidentified interactive controls:\n"
                + deduplicated.map(\.description).sorted().joined(separator: "\n")
        )
    }

    // MARK: Settings panes

    /// Every Settings pane, audited through the real Settings scene. The
    /// window retitles to the selected pane, so it is re-resolved by title
    /// after each sidebar click.
    func testSettingsPanesCarryIdentifiers() throws {
        let app = self.session.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(
            app.windows["General"].waitForExistence(timeout: 10),
            "Settings should open on the General pane"
        )

        // Sidebar order from `SettingsSection.sidebar(includeScrobble: true)`.
        // Selection is walked with the down-arrow key: AppKit auto-scrolls
        // keyboard selection, which sidesteps both the below-the-fold click
        // problem and the section-header/pane text collisions ("Library",
        // "Playback", "Advanced" are each a header AND a pane).
        let orderedPanes = [
            "General", "Appearance", "Library", "Sources", "Smart Playlists",
            "Podcasts", "Phone Sync", "Playback", "Equaliser", "Effects",
            "ReplayGain", "Lyrics", "Visualizer", "Scrobbling", "Advanced",
            "Diagnostics",
        ]
        var violations: Set<Violation> = []

        let generalRow = app.windows["General"].outlines.firstMatch
            .staticTexts["General"].firstMatch
        XCTAssertTrue(generalRow.waitForExistence(timeout: 5))
        generalRow.click()

        for (index, pane) in orderedPanes.enumerated() {
            if index > 0 {
                app.typeKey(.downArrow, modifierFlags: [])
            }
            Thread.sleep(forTimeInterval: 0.4)
            var paneWindow = app.windows[pane]
            if index > 0, !paneWindow.waitForExistence(timeout: 3) {
                // A pane's content can steal keyboard focus from the
                // sidebar (Advanced does), eating the arrow key. The walk
                // has scrolled the row on-screen by now, so click it.
                let previous = app.windows[orderedPanes[index - 1]]
                let row = previous.outlines.firstMatch.staticTexts[pane].firstMatch
                if row.exists {
                    row.click()
                    Thread.sleep(forTimeInterval: 0.4)
                }
                paneWindow = app.windows[pane]
            }
            guard paneWindow.waitForExistence(timeout: 5) else {
                XCTFail("Settings window did not retitle to \"\(pane)\"")
                continue
            }
            try violations.formUnion(self.audit(window: paneWindow, surface: "settings.\(pane)"))
        }

        let deduplicated = Self.dedupeAcrossSurfaces(violations)
        XCTAssertTrue(
            deduplicated.isEmpty,
            "Unidentified interactive controls:\n"
                + deduplicated.map(\.description).sorted().joined(separator: "\n")
        )
    }

    // MARK: Secondary windows

    /// Log Console, Equaliser & DSP, Library Summary, the mini player in
    /// all four layouts, About, Notices, and the Help book. Track Info
    /// (needs a selection), the full-screen visualizer, and the DEBUG-only
    /// audio window are covered by the surface-crawl phases instead.
    func testSecondaryWindowsCarryIdentifiers() throws {
        let app = self.session.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.waitForTrackRows(timeout: 60))

        var violations: Set<Violation> = []

        /// Opens a window via `open`, waits for the window count to grow
        /// (titles are unreliable: the About panel's AX title is not its
        /// scene title), audits every open window, then closes the new one.
        func openAuditClose(surface: String, open: () -> Void) throws {
            let before = app.windows.count
            open()
            let deadline = Date().addingTimeInterval(10)
            while app.windows.count <= before, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
            guard app.windows.count > before else {
                XCTFail("\(surface) window did not open")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
            for index in 0 ..< app.windows.count {
                let window = app.windows.element(boundBy: index)
                guard window.exists else { continue }
                try violations.formUnion(self.audit(window: window, surface: surface))
            }
            app.typeKey("w", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.3)
        }

        let menuBar = app.menuBars.firstMatch

        try openAuditClose(surface: "logConsole") {
            app.typeKey("l", modifierFlags: [.command, .shift])
        }
        try openAuditClose(surface: "dsp") {
            app.typeKey("e", modifierFlags: [.command, .option])
        }
        try openAuditClose(surface: "librarySummary") {
            menuBar.menuBarItems["Tools"].click()
            menuBar.menuItems["Library Summary\u{2026}"].click()
        }
        try openAuditClose(surface: "about") {
            menuBar.menuBarItems["Bòcan Music"].click()
            menuBar.menuBarItems["Bòcan Music"].menuItems["About Bòcan"].click()
        }
        try openAuditClose(surface: "notices") {
            menuBar.menuBarItems["Help"].click()
            menuBar.menuItems["Notices \u{26} Licences\u{2026}"].click()
        }
        try openAuditClose(surface: "helpBook") {
            menuBar.menuBarItems["Help"].click()
            menuBar.menuItems["Bòcan Music Help"].click()
        }

        // Mini player: the toolbar toggle swaps the main window out, so
        // audit each of the four layouts, then dismiss to restore.
        app.buttons["toolbar.miniPlayer"].firstMatch.click()
        let mini = app.windows["Mini Player"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10), "Mini player did not open")
        let layouts = ["strip", "compact", "square", "visualizer"]
        for layout in layouts {
            Thread.sleep(forTimeInterval: 0.4)
            try violations.formUnion(self.audit(window: mini, surface: "miniPlayer.\(layout)"))
            if layout != layouts.last {
                // Chrome is hover-revealed in some layouts; hover first.
                mini.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
                mini.buttons["miniPlayer.layout"].firstMatch.click()
            }
        }
        mini.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        mini.buttons["miniPlayer.dismiss"].firstMatch.click()

        let deduplicated = Self.dedupeAcrossSurfaces(violations)
        XCTAssertTrue(
            deduplicated.isEmpty,
            "Unidentified interactive controls:\n"
                + deduplicated.map(\.description).sorted().joined(separator: "\n")
        )
    }

    /// Keeps one violation per (type, label), preferring the earliest
    /// surface alphabetically, so shared chrome doesn't flood the report.
    /// Empty-label controls stay per-surface: they are distinct controls
    /// that would otherwise collapse into one whack-a-mole entry.
    private static func dedupeAcrossSurfaces(_ violations: Set<Violation>) -> [Violation] {
        var byControl: [String: Violation] = [:]
        for violation in violations.sorted(by: { $0.surface < $1.surface }) {
            let key = violation.label.isEmpty
                ? "\(violation.surface)|\(violation.type)|\(violation.frame)"
                : "\(violation.type)|\(violation.label)"
            if byControl[key] == nil { byControl[key] = violation }
        }
        return Array(byControl.values)
    }
}
