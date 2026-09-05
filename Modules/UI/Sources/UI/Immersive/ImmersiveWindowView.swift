import AppKit // full-screen entry needs the NSWindow
import SwiftUI

// MARK: - ImmersiveWindowView

/// Content of the Immersive Mode window (ADR-089): ``ImmersiveView`` filling
/// a hidden-title-bar window, the way the fullscreen visualizer does.
///
/// Immersive Mode is its own window, not an overlay in the main window: an
/// overlay can never hide that window's own chrome (the toolbar, the split
/// view's sidebar header), and "immersive" means no chrome at all. The
/// window takes itself to system full screen as soon as it appears (SwiftUI
/// scenes have no modifier for that, so it is the same AppKit step the
/// fullscreen visualizer uses to move itself to a screen); `Esc` closes it,
/// which leaves full screen with it.
///
/// The `ui.immersive.visible` preference mirrors whether this window is
/// open: set on appear, cleared on disappear. The toolbar button and the
/// View menu item read it for their labels and open or dismiss the window;
/// `BocanRootView` reopens the window on launch when it was left open, the
/// same way the mini player restores.
public struct ImmersiveWindowView: View {
    @ObservedObject private var library: LibraryViewModel
    @ObservedObject private var lyricsVM: LyricsViewModel
    @ObservedObject private var visualizerVM: VisualizerViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(ImmersiveView.preferenceKey) private var isOpen = false

    /// The scene identifier in `BocanApp`.
    public static let windowID = "immersive"

    public init(library: LibraryViewModel, lyricsVM: LyricsViewModel, visualizerVM: VisualizerViewModel) {
        self.library = library
        self.lyricsVM = lyricsVM
        self.visualizerVM = visualizerVM
    }

    public var body: some View {
        ImmersiveView(library: self.library, lyricsVM: self.lyricsVM, visualizerVM: self.visualizerVM) {
            self.dismissWindow(id: Self.windowID)
        }
        .ignoresSafeArea()
        .background(ImmersiveFullScreenEnforcer().frame(width: 0, height: 0).allowsHitTesting(false))
        .onAppear { self.isOpen = true }
        .onDisappear { self.isOpen = false }
        .onKeyPress(.escape) {
            self.dismissWindow(id: Self.windowID)
            return .handled
        }
    }

    /// Toggles `window` into system full screen. A no-op while the window is
    /// not yet on screen (AppKit ignores the toggle then) or already there (a
    /// relaunch restore, say). Returns whether the toggle was requested.
    @MainActor
    @discardableResult
    static func enterFullScreenIfNeeded(_ window: NSWindow?) -> Bool {
        guard let window, window.isVisible, !window.styleMask.contains(.fullScreen) else { return false }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
        return true
    }
}

// MARK: - ImmersiveFullScreenEnforcer

/// Zero-size helper that reaches the exact `NSWindow` hosting the Immersive
/// Mode content, the way `MainWindowGrabber` reaches the main window, and
/// asks for full screen once the window is attached and visible. A timed
/// lookup by title ran before the window was on screen and was ignored.
private struct ImmersiveFullScreenEnforcer: NSViewRepresentable {
    final class Coordinator {
        var requested = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        self.request(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        self.request(from: nsView, coordinator: context.coordinator)
    }

    private func request(from view: NSView, coordinator: Coordinator) {
        guard !coordinator.requested else { return }
        DispatchQueue.main.async {
            guard !coordinator.requested else { return }
            if ImmersiveWindowView.enterFullScreenIfNeeded(view.window) {
                coordinator.requested = true
            }
        }
    }
}
