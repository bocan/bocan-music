import AppKit // AppKit drop-down: cursor hiding + screen management require NSCursor / NSScreen
import SwiftUI

// MARK: - VisualizerFullscreenView

/// Content of the fullscreen visualizer window.
///
/// - Black background, no title bar chrome (set on the containing `Window` scene).
/// - Cursor auto-hides 2 s after the last mouse movement; restored on close or movement.
/// - `Esc` closes the window.
public struct VisualizerFullscreenView: View {
    @ObservedObject public var vm: VisualizerViewModel
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var cursorHideTask: Task<Void, Never>?

    public init(vm: VisualizerViewModel) {
        self.vm = vm
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VisualizerHost(vm: self.vm)
        }
        .ignoresSafeArea()
        .onAppear {
            self.vm.start()
            self.scheduleCursorHide()
        }
        .onDisappear {
            self.vm.stop()
            self.cursorHideTask?.cancel()
            // Restore cursor unconditionally — setHiddenUntilMouseMoves(false)
            // is safe to call even when the cursor is already visible.
            NSCursor.setHiddenUntilMouseMoves(false)
        }
        .onKeyPress(.escape) {
            self.dismissWindow(id: "visualizer-fullscreen")
            return .handled
        }
        .onContinuousHover { _ in
            // Mouse moved: cursor is already restored automatically by
            // setHiddenUntilMouseMoves. Just reschedule the next hide.
            self.scheduleCursorHide()
        }
        .accessibilityLabel("Fullscreen Visualizer: \(self.vm.mode.displayName)")
    }

    // MARK: - Cursor management

    private func scheduleCursorHide() {
        self.cursorHideTask?.cancel()
        self.cursorHideTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            // One-shot hide: cursor reappears automatically on next mouse move.
            // No matching unhide() call needed — no ref-count to misbalance.
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}
