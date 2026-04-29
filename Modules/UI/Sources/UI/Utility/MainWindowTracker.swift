import AppKit
import SwiftUI

// MARK: - MainWindowTracker

/// Holds a weak reference to the main app window so MiniPlayerView can hide
/// and restore it without relying on window titles (changed by NavigationSplitView)
/// or SwiftUI's DismissWindowAction (unreliable for WindowGroup self-dismissal).
@MainActor
final class MainWindowTracker {
    static let shared = MainWindowTracker()

    private init() {}

    weak var window: NSWindow?
}

// MARK: - MiniPlayerWindowTracker

/// Holds a weak reference to the mini player window so MiniPlayerView can
/// resize it when the user cycles layouts.
@MainActor
final class MiniPlayerWindowTracker {
    static let shared = MiniPlayerWindowTracker()

    private init() {}

    weak var window: NSWindow?
}

// MARK: - MainWindowGrabber

/// Zero-size NSViewRepresentable placed in BocanRootView.  Captures the containing
/// NSWindow as soon as the view is added to the hierarchy and keeps the reference
/// current across subsequent updates.
struct MainWindowGrabber: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            MainWindowTracker.shared.window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            // Only update when non-nil: orderOut hides the window but keeps the
            // NSWindow alive; clearing the reference here would break restore.
            if let win = nsView.window {
                MainWindowTracker.shared.window = win
            }
        }
    }
}

// MARK: - MiniPlayerWindowSetup

/// Zero-size NSViewRepresentable placed in MiniPlayerView.  Excludes the mini
/// player window from the Window menu and captures a reference for layout-driven
/// resize.  Uses an NSView subclass so viewDidMoveToWindow() fires exactly when
/// the window reference becomes available — DispatchQueue.main.async is not
/// sufficient because view.window is nil when makeNSView returns.
struct MiniPlayerWindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowMenuExcludeView {
        WindowMenuExcludeView()
    }

    func updateNSView(_ nsView: WindowMenuExcludeView, context: Context) {}
}

final class WindowMenuExcludeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isExcludedFromWindowsMenu = true
        // viewDidMoveToWindow is always called on the main thread.
        MainActor.assumeIsolated {
            MiniPlayerWindowTracker.shared.window = self.window
        }
    }
}

// MARK: - SidebarWidthAutosave

/// Phase 4 audit H2: enables AppKit's built-in `NSSplitView` autosave so the
/// sidebar divider position survives app relaunches, and reports width
/// changes back to `LibraryViewModel` so we can also persist via the
/// `ui.state.v2` settings key (cross-machine profile portability).
///
/// SwiftUI's `NavigationSplitView` does not expose its underlying
/// `NSSplitView` directly, so we walk the window's content view hierarchy
/// once the view is mounted, set `autosaveName`, and install a delegate
/// that forwards divider moves.
struct SidebarWidthAutosave: NSViewRepresentable {
    let initialWidth: Double?
    let onWidthChange: (Double) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.attach(to: view, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            self.attach(to: nsView, coordinator: context.coordinator)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onWidthChange: self.onWidthChange)
    }

    private func attach(to view: NSView, coordinator: Coordinator) {
        guard coordinator.attached == false,
              let window = view.window,
              let splitView = Self.findSplitView(in: window.contentView) else { return }
        splitView.autosaveName = "BocanRootSplitView"
        if coordinator.previousDelegate == nil {
            coordinator.previousDelegate = splitView.delegate
        }
        coordinator.splitView = splitView
        splitView.delegate = coordinator
        coordinator.attached = true

        // Seed initial width if AppKit's autosave didn't already restore one
        // larger than the SwiftUI default.  Negative / zero widths are ignored.
        if let width = initialWidth, width > 0,
           splitView.arrangedSubviews.count >= 2 {
            splitView.setPosition(CGFloat(width), ofDividerAt: 0)
        }
    }

    private static func findSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let found = Self.findSplitView(in: child) { return found }
        }
        return nil
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        let onWidthChange: (Double) -> Void
        weak var splitView: NSSplitView?
        weak var previousDelegate: NSSplitViewDelegate?
        var attached = false

        init(onWidthChange: @escaping (Double) -> Void) {
            self.onWidthChange = onWidthChange
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            self.previousDelegate?.splitViewDidResizeSubviews?(notification)
            guard let splitView,
                  let sidebar = splitView.arrangedSubviews.first else { return }
            self.onWidthChange(Double(sidebar.frame.width))
        }
    }
}
