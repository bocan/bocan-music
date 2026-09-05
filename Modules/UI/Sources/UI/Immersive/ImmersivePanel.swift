import SwiftUI

// MARK: - ImmersivePanel

/// The translucent card an Immersive Mode column sits in (ADR-089).
///
/// Clear Liquid Glass on macOS 26 over a light dimming layer (the treatment
/// Apple documents for the clear variant, so text stays legible), a thin
/// material on macOS 15: both let the visualizer running beneath read
/// through. Reduce Transparency turns the card solid, and Increase Contrast
/// makes the hairline a full separator, matching `AdaptiveMaterialBackground`.
///
/// `surface: false` keeps the accessibility container and the sizing but
/// draws no card at all: the now-playing column floats straight on the
/// visualizer, so the three columns do not read as three equal boxes.
///
/// Sets `.accessibilityElement(children: .contain)` so a caller can attach a
/// label and an identifier to the column without merging its children.
struct ImmersivePanel: ViewModifier {
    var surface = true

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.bocanHighContrast) private var overrideHighContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Softer than `Theme.cornerRadiusLarge`: these are floating cards, not panes.
    static let cornerRadius: CGFloat = 16

    private var highContrast: Bool {
        self.overrideHighContrast ?? (self.colorSchemeContrast == .increased)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ImmersivePanelSurface(
                enabled: self.surface,
                shape: self.shape,
                reduceTransparency: self.reduceTransparency
            ))
            // A faint hairline keeps the card's edge readable when the field
            // behind it is quiet (the oscilloscope is a single line on black
            // between beats); Increase Contrast makes it a full separator.
            .overlay {
                if self.surface {
                    self.shape.strokeBorder(
                        self.highContrast ? Color.separatorAdaptive : Color.white.opacity(0.10),
                        lineWidth: 1
                    )
                }
            }
            .accessibilityElement(children: .contain)
    }
}

// MARK: - ImmersivePanelSurface

/// The card surface: clear glass where the OS has it, material below, solid
/// under Reduce Transparency, nothing when disabled. Kept as its own modifier
/// so the availability branch stays in one place.
private struct ImmersivePanelSurface: ViewModifier {
    let enabled: Bool
    let shape: RoundedRectangle
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if !self.enabled {
            content
        } else if self.reduceTransparency {
            content.background(Color.bgPrimary, in: self.shape)
        } else if #available(macOS 26, *) {
            content
                .background(Color.black.opacity(0.18), in: self.shape)
                .glassEffect(.clear, in: self.shape)
        } else {
            content.background(.ultraThinMaterial, in: self.shape)
        }
    }
}

extension View {
    /// Wraps the view in a translucent Immersive Mode column card, or in a
    /// surface-less column with the same sizing and accessibility container.
    func immersivePanel(surface: Bool = true) -> some View {
        modifier(ImmersivePanel(surface: surface))
    }
}
