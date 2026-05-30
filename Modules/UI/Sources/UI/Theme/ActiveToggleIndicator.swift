import SwiftUI

// MARK: - ActiveToggleIndicator

/// Adds a shape-based "active" affordance to toggle-style controls so that an
/// enabled toggle can be told apart from a disabled one without relying on the
/// accent-vs-tertiary colour difference alone.
///
/// When `accessibilityDifferentiateWithoutColor` is enabled and `isActive` is
/// `true`, a small filled dot is drawn beneath the control (mirroring the macOS
/// Dock running-app indicator). When the preference is off the control is left
/// untouched so the default appearance is preserved.
private struct ActiveToggleIndicator: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if self.isActive, self.differentiateWithoutColor {
                Circle()
                    .fill(Color.textPrimary)
                    .frame(width: 3, height: 3)
                    .offset(y: 5)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - View extension

extension View {
    /// Draws a shape-based "active" indicator beneath a toggle control when
    /// "Differentiate Without Color" is enabled, so on/off state is never
    /// conveyed by colour alone (WCAG 1.4.1).
    func activeToggleIndicator(_ isActive: Bool) -> some View {
        modifier(ActiveToggleIndicator(isActive: isActive))
    }
}
