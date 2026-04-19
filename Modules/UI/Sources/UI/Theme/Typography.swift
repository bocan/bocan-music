import SwiftUI

/// Semantic font roles used throughout Bòcan.
///
/// All roles use Dynamic Type via `.font(Typography.body)` rather than fixed
/// point sizes, honouring the user's preferred reading size.
public enum Typography {
    /// Large title (headline).  Maps to `.title`.
    public static let largeTitle: Font = .title

    /// Section / album title.   Maps to `.headline`.
    public static let title: Font = .headline

    /// Primary body text.       Maps to `.body`.
    public static let body: Font = .body

    /// Secondary metadata.      Maps to `.subheadline`.
    public static let subheadline: Font = .subheadline

    /// Timestamps / footnotes.  Maps to `.footnote`.
    public static let footnote: Font = .footnote

    /// Table header labels.     Maps to `.caption`.
    public static let caption: Font = .caption

    /// Numeric counters / tiny labels.  Maps to `.caption2`.
    public static let mini: Font = .caption2
}
