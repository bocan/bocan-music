import SwiftUI

// MARK: - ImmersiveOverlay

/// Lays ``ImmersiveView`` over the main window's content while
/// `ui.immersive.visible` is on (ADR-089). Applied once, to the whole window
/// content in `BocanRootView`, so the overlay covers the split view, the
/// trailing pane slot and the transport strip alike.
///
/// The preference is a `View`-level `@AppStorage`, the same as the lyrics and
/// visualizer pane flags: it must not live on an `ObservableObject` held by
/// the `App` struct (see `WindowModeController`). The menu item, the strip
/// button and the Esc hook all toggle this one key.
///
/// The window toolbar stays. Hiding `.windowToolbar` removes the title bar
/// and the traffic lights with it, which is more than immersive should take
/// from a regular window; the toolbar sits above the content area, so it
/// never overlaps the columns.
struct ImmersiveOverlay: ViewModifier {
    let library: LibraryViewModel
    let lyricsVM: LyricsViewModel
    let visualizerVM: VisualizerViewModel

    @AppStorage(Self.preferenceKey) private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The one preference every entry and exit path flips.
    static let preferenceKey = "ui.immersive.visible"

    func body(content: Content) -> some View {
        content
            .overlay {
                if self.visible {
                    ImmersiveView(
                        library: self.library,
                        lyricsVM: self.lyricsVM,
                        visualizerVM: self.visualizerVM
                    ) {
                        self.visible = false
                    }
                    .transition(.opacity)
                }
            }
            .animation(self.reduceMotion ? nil : Theme.Animation.default, value: self.visible)
    }
}
