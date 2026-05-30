import SwiftUI

// MARK: - ScaledSystemFont

/// Applies a system font of a fixed base point size that still scales with
/// Dynamic Type.
///
/// A plain fixed-point system font is *not* affected by the user's preferred
/// text size, so transport icons and compact labels built with it stay frozen at
/// one size. This modifier drives the same size through `@ScaledMetric`, so the
/// glyph or label grows and shrinks with the accessibility text-size setting
/// while rendering at exactly the base size at the default `.large`
/// content-size category (keeping existing layouts and snapshots stable).
private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo textStyle: Font.TextStyle) {
        self._size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: self.size, weight: self.weight, design: self.design))
    }
}

// MARK: - View extension

extension View {
    /// A system font of fixed base `size` that scales with Dynamic Type via
    /// `@ScaledMetric`. Prefer this over `.font(.system(size:))` for icon glyphs
    /// and compact labels whose precise base size matters but which must still
    /// honour the user's text-size preference.
    func scaledSystemFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design, relativeTo: textStyle))
    }
}
