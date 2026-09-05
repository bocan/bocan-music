import SwiftUI

// MARK: - ImmersivePanel

/// The translucent card each Immersive Mode column sits in (ADR-089).
///
/// Liquid Glass on macOS 26, a thin material on macOS 15: both blur the
/// visualizer running beneath, so the oscilloscope reads through the cards
/// rather than being hidden by them. Reduce Transparency turns the card
/// solid, and Increase Contrast adds a separator border, matching
/// `AdaptiveMaterialBackground`'s upgrades.
///
/// Sets `.accessibilityElement(children: .contain)` so a caller can attach a
/// label and an identifier to the column without merging its children.
struct ImmersivePanel: ViewModifier {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.bocanHighContrast) private var overrideHighContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var highContrast: Bool {
        self.overrideHighContrast ?? (self.colorSchemeContrast == .increased)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ImmersivePanelSurface(shape: self.shape, reduceTransparency: self.reduceTransparency))
            // A faint hairline keeps the card's edge readable when the field
            // behind it is quiet (the oscilloscope is a single line on black
            // between beats); Increase Contrast makes it a full separator.
            .overlay {
                self.shape.strokeBorder(
                    self.highContrast ? Color.separatorAdaptive : Color.white.opacity(0.14),
                    lineWidth: 1
                )
            }
            .accessibilityElement(children: .contain)
    }
}

// MARK: - ImmersivePanelSurface

/// The card surface: glass where the OS has it, material below, solid under
/// Reduce Transparency. Kept as its own modifier so the availability branch
/// stays in one place.
private struct ImmersivePanelSurface: ViewModifier {
    let shape: RoundedRectangle
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if self.reduceTransparency {
            content.background(Color.bgPrimary, in: self.shape)
        } else if #available(macOS 26, *) {
            // A whisper of tint under the glass so the card still reads on
            // a black field; the glass supplies the blur and the highlight.
            content
                .background(Color.white.opacity(0.05), in: self.shape)
                .glassEffect(.regular, in: self.shape)
        } else {
            content.background(.ultraThinMaterial, in: self.shape)
        }
    }
}

extension View {
    /// Wraps the view in a translucent Immersive Mode column card.
    func immersivePanel() -> some View {
        modifier(ImmersivePanel())
    }
}
