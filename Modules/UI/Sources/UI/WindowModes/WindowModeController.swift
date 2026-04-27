import AppKit
import SwiftUI

// MARK: - WindowModeController

/// Manages toggling between the main window and the Mini Player.
///
/// Inject into the environment and call `toggleMiniPlayer()` from the keyboard
/// shortcut or menu bar.
///
/// Opening a window that is already open just brings it forward — so we track
/// the desired mode in `@AppStorage` and call `openWindow`/`dismissWindow`
/// accordingly.
@MainActor
public final class WindowModeController: ObservableObject {
    // MARK: - Persisted state

    /// @Published + manual UserDefaults read/write instead of @AppStorage.
    /// @AppStorage in an ObservableObject that is a @StateObject in an App struct
    /// subscribes to UserDefaults.didChangeNotification (key-agnostic), which fires
    /// whenever macOS autosaves window frames — triggering objectWillChange → infinite
    /// App body re-evaluation loop at display-refresh rate.
    @Published public var miniPlayerOpen: Bool {
        didSet { UserDefaults.standard.set(self.miniPlayerOpen, forKey: "ui.windowMode.miniPlayerOpen") }
    }

    @Published public var restoresLastMode: Bool {
        didSet { UserDefaults.standard.set(self.restoresLastMode, forKey: "ui.windowMode.restoresLastMode") }
    }

    // MARK: - Environment

    /// Must be set from inside a SwiftUI view that has the environment values.
    public var openWindow: ((String) -> Void)?
    public var dismissWindow: ((String) -> Void)?

    public init() {
        self.miniPlayerOpen = UserDefaults.standard.bool(forKey: "ui.windowMode.miniPlayerOpen")
        let stored = UserDefaults.standard.object(forKey: "ui.windowMode.restoresLastMode") as? Bool
        self.restoresLastMode = stored ?? true
    }

    // MARK: - Public API

    /// Toggle the Mini Player window (⌘⌥M).
    public func toggleMiniPlayer() {
        if self.miniPlayerOpen {
            self.dismissWindow?("mini")
            self.miniPlayerOpen = false
            // Restore main window directly; MiniPlayerView.onDisappear does the
            // same but SwiftUI's DismissWindowAction may fire it after a delay
            // or not at all if the main window is currently hidden via orderOut.
            if let win = MainWindowTracker.shared.window {
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                self.openWindow?("main")
            }
        } else {
            self.openWindow?("mini")
            self.miniPlayerOpen = true
        }
    }

    /// Show the Mini Player without closing the main window.
    public func showMiniPlayer() {
        self.openWindow?("mini")
        self.miniPlayerOpen = true
    }

    /// Restore window mode on launch.
    public func restoreIfNeeded() {
        guard self.restoresLastMode, self.miniPlayerOpen else { return }
        self.openWindow?("mini")
    }
}
