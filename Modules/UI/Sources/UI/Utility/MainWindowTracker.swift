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
/// player window from the automatic Window menu listing.
///
/// Uses a custom NSView subclass so viewDidMoveToWindow() fires at the exact
/// moment the window reference becomes available — DispatchQueue.main.async is
/// not sufficient because view.window is still nil when makeNSView returns.
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
    }
}
