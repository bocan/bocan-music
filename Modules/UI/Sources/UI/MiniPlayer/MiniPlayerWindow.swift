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
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 72)
        .defaultPosition(.bottomTrailing)
        .windowToolbarStyle(.unifiedCompact)
    }
}
