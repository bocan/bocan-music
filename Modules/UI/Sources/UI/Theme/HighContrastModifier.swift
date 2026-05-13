import SwiftUI

extension EnvironmentValues {
    /// Snapshot-test override for `colorSchemeContrast == .increased`.
    ///
    /// When `nil` (the default), views fall back to the system
    /// `colorSchemeContrast` environment value.
    @Entry var bocanHighContrast: Bool?
}

// MARK: - AdaptiveMaterialBackground

/// Applies `.ultraThinMaterial` normally and upgrades to `.regularMaterial`
/// when `colorSchemeContrast == .increased` (i.e. the user has enabled
/// "Increase Contrast" in Accessibility settings) or its test override is set.
/// When `accessibilityReduceTransparency` is on the surface becomes fully
/// opaque (`windowBackgroundColor`) overriding both material variants.
///
/// The more opaque material keeps chrome panels readable for users who need
/// stronger visual contrast between UI surfaces and background content.
private struct AdaptiveMaterialBackground: ViewModifier {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.bocanHighContrast) private var overrideHighContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var highContrast: Bool {
        self.overrideHighContrast ?? (self.colorSchemeContrast == .increased)
    }

    func body(content: Content) -> some View {
        if self.reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor))
        } else if self.highContrast {
            content.background(.regularMaterial)
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}

// MARK: - View extension

extension View {
    /// Applies `.ultraThinMaterial` background normally, upgrading to
    /// `.regularMaterial` when "Increase Contrast" is enabled in Accessibility
    /// settings (or the test override is set via `\.bocanHighContrast`), and
    /// switching to a solid `windowBackgroundColor` when "Reduce Transparency"
    /// is on so no translucent surface remains.
    func adaptiveMaterial() -> some View {
        modifier(AdaptiveMaterialBackground())
    }
}
