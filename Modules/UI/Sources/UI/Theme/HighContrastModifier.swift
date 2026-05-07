import SwiftUI

extension EnvironmentValues {
    // Snapshot-test override for `colorSchemeContrast == .increased`.
    //
    // When `nil` (the default), views fall back to the system
    // `colorSchemeContrast` environment value.
    @Entry var bocanHighContrast: Bool?
}

// MARK: - AdaptiveMaterialBackground

/// Applies `.ultraThinMaterial` normally and upgrades to `.regularMaterial`
/// when `colorSchemeContrast == .increased` (i.e. the user has enabled
/// "Increase Contrast" in Accessibility settings) or its test override is set.
///
/// The more opaque material keeps chrome panels readable for users who need
/// stronger visual contrast between UI surfaces and background content.
private struct AdaptiveMaterialBackground: ViewModifier {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.bocanHighContrast) private var overrideHighContrast

    private var highContrast: Bool {
        self.overrideHighContrast ?? (self.colorSchemeContrast == .increased)
    }

    func body(content: Content) -> some View {
        if self.highContrast {
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
    /// settings (or the test override is set via `\.bocanHighContrast`).
    func adaptiveMaterial() -> some View {
        modifier(AdaptiveMaterialBackground())
    }
}
