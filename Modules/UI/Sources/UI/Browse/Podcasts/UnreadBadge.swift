import SwiftUI

// MARK: - UnreadBadge

/// A small accent-filled count pill overlaid on podcast artwork, showing how
/// many episodes of a show are unplayed.
///
/// The visible numeral is rendered via a number formatter (`count.formatted()`),
/// never a localized string: concatenating a number with a localized noun would
/// break non-trailing-plural languages and trip the no-bare-literal lint. The
/// plural-aware accessibility label is supplied by the parent cell instead.
struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(verbatim: self.count.formatted())
            .font(.caption2)
            .fontWeight(.semibold)
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor, in: Capsule())
    }
}
