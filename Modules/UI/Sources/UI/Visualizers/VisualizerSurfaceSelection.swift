import Foundation

// MARK: - VisualizerSurfaceSelection

/// What one ``VisualizerHost`` surface renders, independent of the user's
/// saved visualizer preference (ADR-089).
///
/// The pane, the mini player and the fullscreen window follow the saved
/// `visualizer.mode` and `visualizer.palette`; they use
/// ``followsPreferences``. A surface with a fixed look, such as Immersive
/// Mode, pins one or both values here instead of writing the shared keys, so
/// entering and leaving it never changes what the other surfaces show.
struct VisualizerSurfaceSelection: Equatable {
    /// The mode this surface renders, or `nil` to follow the saved preference.
    var mode: VisualizerMode?
    /// The palette this surface renders, or `nil` to follow the saved preference.
    var palette: VisualizerPalette?

    /// The default: render whatever the user last chose.
    static let followsPreferences = Self(mode: nil, palette: nil)

    /// True when at least one of mode or palette is pinned. A pinned surface
    /// is decoupled from the shared preference in both directions: it ignores
    /// changes to the saved value, and its own frame-rate watchdog must not
    /// rewrite the saved value through auto-simplify.
    var overridesPreferences: Bool {
        self.mode != nil || self.palette != nil
    }

    func effectiveMode(preferred: VisualizerMode) -> VisualizerMode {
        self.mode ?? preferred
    }

    func effectivePalette(preferred: VisualizerPalette) -> VisualizerPalette {
        self.palette ?? preferred
    }

    /// The identity a host gives its renderer. A change tears the renderer
    /// down and rebuilds it; an unchanged key is a no-op.
    static func rendererKey(
        mode: VisualizerMode,
        palette: VisualizerPalette,
        reduceMotion: Bool,
        reduceTransparency: Bool
    ) -> String {
        "\(mode.rawValue)-\(palette.rawValue)-\(reduceMotion)-\(reduceTransparency)"
    }
}
