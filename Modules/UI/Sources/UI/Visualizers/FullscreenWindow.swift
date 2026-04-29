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
    @State private var cursorHidden = false

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
            self.showCursor()
        }
        .onKeyPress(.escape) {
            self.dismissWindow(id: "visualizer-fullscreen")
            return .handled
        }
        .onContinuousHover { _ in
            self.showCursor()
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
            self.hideCursor()
        }
    }

    private func hideCursor() {
        guard !self.cursorHidden else { return }
        self.cursorHidden = true
        NSCursor.hide()
    }

    private func showCursor() {
        guard self.cursorHidden else { return }
        self.cursorHidden = false
        NSCursor.unhide()
    }
}
