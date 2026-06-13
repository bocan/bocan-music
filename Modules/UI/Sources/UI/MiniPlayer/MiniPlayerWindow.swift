import SwiftUI

// MARK: - MiniPlayerWindow

/// SwiftUI `Scene` that hosts the Mini Player window.
///
/// Add this to `BocanApp.body`:
/// ```swift
/// MiniPlayerWindow(vm: miniPlayerVM)
/// ```
public struct MiniPlayerWindow: Scene {
    private let vm: MiniPlayerViewModel

    public init(vm: MiniPlayerViewModel) {
        self.vm = vm
    }

    public var body: some Scene {
        Window("Mini Player", id: "mini") {
            MiniPlayerView(vm: self.vm)
        }
        // .contentMinSize (not .contentSize) keeps the window user-resizable: the
        // content sets the minimum, and the per-layout snap in MiniPlayerView sticks.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 585, height: 145)
        .defaultPosition(.bottomTrailing)
        .windowStyle(.hiddenTitleBar)
        // SwiftUI's `Window` scene auto-injects a "Mini Player" item into the
        // Window menu (a one-shot show that can't toggle back to the main
        // window).  `commandsRemoved()` strips that auto-generated command;
        // users still get the working "Toggle Miniplayer" item we add via
        // `.commands` in `BocanApp`.
        .commandsRemoved()
    }
}
