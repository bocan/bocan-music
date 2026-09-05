import SwiftUI

// MARK: - ImmersivePanel

/// The translucent card each Immersive Mode column sits in (ADR-089).
///
/// A plain tinted fill, deliberately not glass or a material: both blur
/// whatever is behind them, and behind these cards is an `MTKView` redrawing
/// at the display rate, so every frame forced an offscreen blur pass over
/// each card and the visualizer stuttered. A half-opaque black tint gives the
/// same "the waveform reads through" effect at no cost, with enough dimming
/// for the text to stay legible. Reduce Transparency turns the card solid,
/// and Increase Contrast makes the hairline a full separator, matching
/// `AdaptiveMaterialBackground`.
///
/// Sets `.accessibilityElement(children: .contain)` so a caller can attach a
/// label and an identifier to the column without merging its children.
struct ImmersivePanel: ViewModifier {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.bocanHighContrast) private var overrideHighContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Softer than `Theme.cornerRadiusLarge`: these are floating cards, not panes.
    static let cornerRadius: CGFloat = 16
    /// How much of the visualizer the tint lets through. Half way between
    /// solid and clear glass by eye; raise it to dim more.
    static let tintOpacity = 0.55

    private var highContrast: Bool {
        self.overrideHighContrast ?? (self.colorSchemeContrast == .increased)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    /// Experiment (2026-09-05): fully opaque, to test whether any
    /// translucency over the live Metal layer is what makes the visualizer
    /// stutter. Restore `Color.black.opacity(Self.tintOpacity)` if it is not.
    private var fill: Color {
        _ = Self.tintOpacity
        // Half way from the window's dark background toward the black field.
        return Color.bgPrimary.mix(with: .black, by: 0.5)
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(self.fill, in: self.shape)
            // A faint hairline keeps the card's edge readable when the field
            // behind it is quiet (the oscilloscope is a single line on black
            // between beats); Increase Contrast makes it a full separator.
            .overlay {
                self.shape.strokeBorder(
                    self.highContrast ? Color.separatorAdaptive : Color.white.opacity(0.12),
                    lineWidth: 1
                )
            }
            .accessibilityElement(children: .contain)
    }
}

extension View {
    /// Wraps the view in a translucent Immersive Mode column card.
    func immersivePanel() -> some View {
        modifier(ImmersivePanel())
    }
}
