import SwiftUI

/// Layout constants for Bòcan's native-macOS UI.
public enum Theme {
    // MARK: - Sidebar

    /// Default sidebar width.
    public static let sidebarWidth: CGFloat = 220

    /// Minimum sidebar width when the user drags the divider.
    public static let sidebarMinWidth: CGFloat = 180

    // MARK: - Rows

    /// Height of a single track row in the table view.
    public static let rowHeight: CGFloat = 28

    /// Height of a single artist/genre row in a List.
    public static let listRowHeight: CGFloat = 36

    // MARK: - Album grid

    /// Minimum cell width in the albums grid.
    public static let albumGridMinWidth: CGFloat = 180

    /// Spacing between cells in the albums grid.
    public static let albumGridSpacing: CGFloat = 16

    // MARK: - Artwork

    /// Artwork thumbnail size in the now-playing strip.
    public static let nowPlayingArtworkSize: CGFloat = 48

    /// Artwork size inside an album grid cell.
    public static let albumArtworkSize: CGFloat = 160

    /// Small artwork shown in track rows.
    public static let rowArtworkSize: CGFloat = 24

    /// Corner radius applied to all artwork thumbnails.
    public static let artworkCornerRadius: CGFloat = 6

    // MARK: - Now-playing strip

    /// Height of the bottom transport strip.
    public static let nowPlayingStripHeight: CGFloat = 72

    // MARK: - Corner radii

    /// Tight corner radius — tags, badges.
    public static let cornerRadiusSmall: CGFloat = 4
    /// Standard corner radius — cards, rows.
    public static let cornerRadiusMedium: CGFloat = 8
    /// Large corner radius — panels.
    public static let cornerRadiusLarge: CGFloat = 10

    // MARK: - Animations

    /// Standard quick transition — hover states.
    public static let animationFast: SwiftUI.Animation = .easeOut(duration: 0.15)

    /// Standard medium transition — panel slides.
    public static let animationNormal: SwiftUI.Animation = .easeOut(duration: 0.25)

    /// Slower full-screen transitions.
    public static let animationSlow: SwiftUI.Animation = .easeOut(duration: 0.40)

    /// Namespace for animation constants (mirrors top-level for ergonomics).
    public enum Animation {
        /// Maps to `Theme.animationFast`.
        public static let fast: SwiftUI.Animation = Theme.animationFast
        /// Maps to `Theme.animationNormal`.
        public static let `default`: SwiftUI.Animation = Theme.animationNormal
        /// Maps to `Theme.animationSlow`.
        public static let slow: SwiftUI.Animation = Theme.animationSlow
    }
}
