import XCTest

// MARK: - ControlContext

/// State captured immediately before a control's action, so a
/// postcondition can assert a *change* (a label flip, a window opening)
/// rather than an absolute value that leaks from the shared container.
@MainActor
struct ControlContext {
    let priorLabel: String
    /// The control's accessibilityValue before the action (toggles that
    /// carry their state as a value: shuffle "on"/"off", repeat, etc.).
    let priorValue: String
    let priorWindowCount: Int
    let priorEnabled: Bool
}

// MARK: - SurfaceControl

/// One control in a surface's crawl table (phase 31): its identifier, how
/// to exercise it, and the concrete postcondition to assert afterward. The
/// array of these per surface is the reviewable artifact, interpreter-driven
/// like the menu manifest. "Did not crash" is never a postcondition; a
/// visual-only control asserts it remains present and the app responsive.
@MainActor
struct SurfaceControl {
    enum Action {
        /// Assert existence only (the click is destructive or networked and
        /// carries a skip reason, or the contract is covered by `verify`).
        case presence
        case click
        case doubleClick
        /// Hover the control's row to reveal it, then click.
        case hoverThenClick
    }

    let identifier: String
    /// Human description for failure messages.
    let name: String
    let action: Action
    /// Postcondition, evaluated after the action against the pre-action
    /// context; returns true when met.
    let verify: @MainActor (XCUIApplication, MenuInvoker, ControlContext) -> Bool
    /// Optional reset (e.g. toggle the control back) run after `verify`.
    var restore: (@MainActor (XCUIApplication, MenuInvoker) -> Void)?
    /// Non-nil when the control is asserted present but not clicked; the
    /// value is the reason (networked, destructive-without-fixture, etc.).
    var skip: String?

    init(
        _ identifier: String,
        _ name: String,
        action: Action = .click,
        skip: String? = nil,
        restore: (@MainActor (XCUIApplication, MenuInvoker) -> Void)? = nil,
        verify: @escaping @MainActor (XCUIApplication, MenuInvoker, ControlContext) -> Bool
    ) {
        self.identifier = identifier
        self.name = name
        self.action = action
        self.skip = skip
        self.restore = restore
        self.verify = verify
    }
}

// MARK: - SurfaceCrawler

/// Interprets a surface's `SurfaceControl` table: for each control, asserts
/// it exists, captures its pre-action context, performs its action (unless
/// skipped), asserts its postcondition, and runs any restore. Reuses
/// `MenuInvoker`'s postcondition helpers.
@MainActor
struct SurfaceCrawler {
    let app: XCUIApplication
    let inv: MenuInvoker

    init(app: XCUIApplication) {
        self.app = app
        self.inv = MenuInvoker(app: app)
    }

    /// Crawls one surface's control table, failing on any missing control
    /// or unmet postcondition. `surface` names the surface in failures.
    func crawl(_ surface: String, _ controls: [SurfaceControl]) {
        for control in controls {
            let element = self.inv.element(control.identifier)
            XCTAssertTrue(
                element.waitForExistence(timeout: 6),
                "[\(surface)] control \(control.identifier) (\(control.name)) is missing"
            )
            let context = ControlContext(
                priorLabel: element.label,
                priorValue: (element.value as? String) ?? "",
                priorWindowCount: self.app.windows.count,
                priorEnabled: element.isEnabled
            )
            if let reason = control.skip {
                XCTAssertFalse(reason.isEmpty, "[\(surface)] \(control.identifier) skip needs a reason")
            } else {
                self.perform(control.action, on: element)
            }
            self.inv.waitFor("[\(surface)] postcondition for \(control.name)") {
                control.verify(self.app, self.inv, context)
            }
            control.restore?(self.app, self.inv)
        }
    }

    private func perform(_ action: SurfaceControl.Action, on element: XCUIElement) {
        switch action {
        case .presence:
            break

        case .click:
            element.click()

        case .doubleClick:
            element.doubleClick()

        case .hoverThenClick:
            element.hover()
            self.inv.settle(0.3)
            element.click()
        }
        self.inv.settle(0.2)
    }
}
