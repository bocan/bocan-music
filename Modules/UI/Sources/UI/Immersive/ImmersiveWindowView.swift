import SwiftUI

// MARK: - ImmersiveWindowView

/// Content of the Immersive Mode window (ADR-089): ``ImmersiveView`` filling
/// a hidden-title-bar window, the way the fullscreen visualizer does.
///
/// Immersive Mode is its own window, not an overlay in the main window: an
/// overlay can never hide that window's own chrome (the toolbar, the split
/// view's sidebar header), and "immersive" means no chrome at all. The
/// window keeps the traffic lights, so it can be zoomed to system full
/// screen like any other; `Esc` closes it.
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
        .onAppear { self.isOpen = true }
        .onDisappear { self.isOpen = false }
        .onKeyPress(.escape) {
            self.dismissWindow(id: Self.windowID)
            return .handled
        }
    }
}
