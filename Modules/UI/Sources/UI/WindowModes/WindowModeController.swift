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

    @AppStorage("ui.windowMode.miniPlayerOpen") public var miniPlayerOpen = false
    @AppStorage("ui.windowMode.restoresLastMode") public var restoresLastMode = true

    // MARK: - Environment

    /// Must be set from inside a SwiftUI view that has the environment values.
    public var openWindow: ((String) -> Void)?
    public var dismissWindow: ((String) -> Void)?

    public init() {}

    // MARK: - Public API

    /// Toggle the Mini Player window (⌘⌥M).
    public func toggleMiniPlayer() {
        if self.miniPlayerOpen {
            self.dismissWindow?("mini")
            self.miniPlayerOpen = false
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
