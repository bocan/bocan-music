import AppKit // AppKit drop-down: cursor hiding + screen management require NSCursor / NSScreen
import SwiftUI

// MARK: - VisualizerFullscreenView

/// Content of the fullscreen visualizer window.
///
/// - Black background, no title bar chrome (set on the containing `Window` scene).
/// - Cursor and HUD controls auto-hide 2 s after the last mouse movement.
/// - `Esc` closes the window.
/// - When multiple displays are connected a screen-picker button at top-trailing
///   lets the user move the window to any available screen. The choice persists via
///   `VisualizerViewModel.targetScreenName` and is restored on next open.
public struct VisualizerFullscreenView: View {
    @ObservedObject public var vm: VisualizerViewModel
    public var nowPlayingVM: NowPlayingViewModel
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var hideTask: Task<Void, Never>?
    @State private var overlayTrigger = 0
    @State private var controlsVisible = true

    public init(vm: VisualizerViewModel, nowPlayingVM: NowPlayingViewModel) {
        self.vm = vm
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VisualizerHost(vm: self.vm)
            NowPlayingOverlay(
                title: self.nowPlayingVM.title,
                artist: self.nowPlayingVM.artist,
                album: self.nowPlayingVM.album,
                fadeAfter: 2,
                refreshTrigger: self.overlayTrigger
            )
        }
        .overlay(alignment: .topTrailing) {
            if NSScreen.screens.count > 1 {
                self.screenPickerButton
                    .padding(12)
                    .opacity(self.controlsVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.5), value: self.controlsVisible)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            self.vm.start()
            self.scheduleHide()
        }
        .task {
            // Allow the window a tick to finish presentation before querying NSApplication.
            try? await Task.sleep(for: .milliseconds(50))
            self.moveToTargetScreen()
        }
        .onDisappear {
            self.vm.stop()
            self.hideTask?.cancel()
            // Restore cursor unconditionally — safe to call even when already visible.
            NSCursor.setHiddenUntilMouseMoves(false)
        }
        .onKeyPress(.escape) {
            self.dismissWindow(id: "visualizer-fullscreen")
            return .handled
        }
        .onContinuousHover { _ in
            // Mouse moved: cursor restored automatically by setHiddenUntilMouseMoves.
            // Reschedule hide and reveal HUD controls + now-playing overlay.
            self.controlsVisible = true
            self.overlayTrigger += 1
            self.scheduleHide()
        }
        .accessibilityLabel("Fullscreen Visualizer: \(self.vm.mode.displayName)")
    }

    // MARK: - Screen picker

    private var screenPickerButton: some View {
        Menu {
            ForEach(NSScreen.screens.indices, id: \.self) { index in
                let screen = NSScreen.screens[index]
                Button {
                    self.vm.targetScreenName = screen.localizedName
                    self.moveToTargetScreen()
                } label: {
                    if screen.localizedName == self.vm.targetScreenName {
                        Label(screen.localizedName, systemImage: "checkmark")
                    } else {
                        Text(screen.localizedName)
                    }
                }
            }
        } label: {
            Label(self.pickerLabel, systemImage: "display")
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
        }
        .help("Move visualizer to a different display")
        .accessibilityLabel("Choose display — currently \(self.pickerLabel)")
    }

    private var pickerLabel: String {
        self.vm.targetScreenName.isEmpty ? "Display" : self.vm.targetScreenName
    }

    // MARK: - Window placement

    /// Moves the fullscreen window to `vm.targetScreenName` if it exists in `NSScreen.screens`.
    private func moveToTargetScreen() {
        let screens = NSScreen.screens
        guard
            screens.count > 1,
            !self.vm.targetScreenName.isEmpty,
            let target = screens.first(where: { $0.localizedName == self.vm.targetScreenName }),
            let window = NSApplication.shared.windows.first(where: { $0.title == "Visualizer" }) else { return }
        window.setFrame(target.frame, display: true, animate: false)
    }

    // MARK: - Cursor + HUD management

    private func scheduleHide() {
        self.hideTask?.cancel()
        self.hideTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
            self.controlsVisible = false
        }
    }
}
