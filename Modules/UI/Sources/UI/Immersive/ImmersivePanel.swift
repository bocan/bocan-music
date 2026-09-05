import SwiftUI

// MARK: - ImmersivePanel

/// The opaque card each Immersive Mode column sits in (ADR-089).
///
/// Solid colour, never a material: ``VisualizerHost`` paints black beneath,
/// so any translucency reads as frosted black rather than a card over the
/// visualizer. The overlay forces a dark scheme, so the adaptive background
/// token resolves to its dark value in both system appearances. Under
/// Increase Contrast a separator border marks the edge, matching
/// `AdaptiveMaterialBackground`'s upgrade.
///
/// Sets `.accessibilityElement(children: .contain)` so a caller can attach a
/// label and an identifier to the column without merging its children.
struct ImmersivePanel: ViewModifier {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.bocanHighContrast) private var overrideHighContrast

    private var highContrast: Bool {
        self.overrideHighContrast ?? (self.colorSchemeContrast == .increased)
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bgPrimary)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous))
            .overlay {
                if self.highContrast {
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous)
                        .strokeBorder(Color.separatorAdaptive, lineWidth: 1)
                }
            }
            .accessibilityElement(children: .contain)
    }
}

extension View {
    /// Wraps the view in an opaque Immersive Mode column card.
    func immersivePanel() -> some View {
        modifier(ImmersivePanel())
    }
}
