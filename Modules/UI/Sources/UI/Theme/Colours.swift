import SwiftUI

// MARK: - Semantic colours

//
// Each colour is defined as a `Color` extension property backed by an
// NSColor adaptive value (light / dark variant). This is equivalent to
// `Color("name", bundle: .module)` from an asset catalogue but lives in
// source, making diffs cleaner and eliminating xcassets JSON churn.
//
// Palette origin: Apple HIG / visual-design reference.

extension Color {
    // MARK: - Background hierarchy

    /// Window / page background.  Light: #FFFFFF  Dark: #1C1C1E
    static let bgPrimary = Color(adaptiveLight: 1, 1, 1, dark: 0.110, 0.110, 0.118)

    /// Sidebar / secondary panels.  Light: #F5F5F7  Dark: #2C2C2E
    static let bgSecondary = Color(adaptiveLight: 0.961, 0.961, 0.969, dark: 0.173, 0.173, 0.180)

    /// Cards / elevated surfaces.  Light: #E8E8ED  Dark: #3A3A3C
    static let bgTertiary = Color(adaptiveLight: 0.910, 0.910, 0.929, dark: 0.227, 0.227, 0.235)

    // MARK: - Text hierarchy

    /// Primary body text.  Light: #1D1D1F  Dark: #F5F5F7
    static let textPrimary = Color(adaptiveLight: 0.114, 0.114, 0.122, dark: 0.961, 0.961, 0.969)

    /// Secondary / metadata text.  Light: #6E6E73  Dark: #98989D
    static let textSecondary = Color(adaptiveLight: 0.431, 0.431, 0.451, dark: 0.596, 0.596, 0.616)

    /// Tertiary / timestamps.
    ///
    /// Values chosen so that WCAG 2.1 AA normal-text contrast (≥ 4.5 : 1) is met
    /// against both `bgPrimary` and `bgSecondary` in both colour schemes.
    ///
    /// Light: #6B6B6F — approx 5.3 : 1 on white (`bgPrimary`) and 4.9 : 1 on
    /// `bgSecondary`.  Previous value #AEAEB2 achieved only ~2.2 : 1 (fail).
    ///
    /// Dark: #939398 — approx 5.5 : 1 on `bgPrimary` and 4.5 : 1 on
    /// `bgSecondary`.  Previous value #636366 achieved only ~2.8 : 1 (fail).
    static let textTertiary = Color(adaptiveLight: 0.420, 0.420, 0.435, dark: 0.576, 0.576, 0.592)

    // MARK: - Interactive

    /// Separator / hairline border.  Low-opacity overlay.
    ///
    /// Automatically strengthens to 0.40 opacity when macOS "Increase Contrast"
    /// is active (detected via the `accessibilityHighContrast*` NSAppearance names).
    static let separatorAdaptive = Color(
        nsColor: NSColor(name: nil) { appearance in
            let highContrastNames: [NSAppearance.Name] = [
                .accessibilityHighContrastAqua,
                .accessibilityHighContrastVibrantLight,
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark,
            ]
            let darkNames: [NSAppearance.Name] = [
                .darkAqua,
                .vibrantDark,
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark,
            ]
            let isHighContrast = highContrastNames.contains(appearance.name)
            let isDark = darkNames.contains(appearance.name)
            let alpha: CGFloat = isHighContrast ? 0.40 : 0.10
            return isDark
                ? NSColor(red: 1, green: 1, blue: 1, alpha: alpha)
                : NSColor(red: 0, green: 0, blue: 0, alpha: alpha)
        }
    )

    /// Star / rating fill.
    ///
    /// Light: #FF5C00 — darkened from the original #FF9500 so that the icon
    /// achieves ≥ 3 : 1 on `bgPrimary` (WCAG 1.4.11 non-text contrast).  The
    /// original value achieved only ~2.2 : 1 (fail).  New value ≈ 3.1 : 1.
    ///
    /// Dark: #FF9F0A — unchanged; already achieves ~8.3 : 1 on dark `bgPrimary`.
    static let ratingFill = Color(adaptiveLight: 1.000, 0.360, 0.000, dark: 1.000, 0.624, 0.039)

    /// Heart / loved tint.  Light: #FF2D55  Dark: #FF375F
    static let lovedTint = Color(adaptiveLight: 1.000, 0.176, 0.333, dark: 1.000, 0.216, 0.373)
}

// MARK: - Private convenience initialiser

private extension Color {
    /// Creates an adaptive `Color` from normalised RGB components.
    init(
        adaptiveLight lr: Double,
        _ lg: Double,
        _ lb: Double,
        dark dr: Double,
        _ dg: Double,
        _ db: Double
    ) {
        self = Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = [
                    NSAppearance.Name.darkAqua,
                    .vibrantDark,
                    .accessibilityHighContrastDarkAqua,
                    .accessibilityHighContrastVibrantDark,
                ].contains(appearance.name)
                return isDark
                    ? NSColor(red: dr, green: dg, blue: db, alpha: 1)
                    : NSColor(red: lr, green: lg, blue: lb, alpha: 1)
            }
        )
    }

    /// Creates an adaptive `Color` with a custom alpha for each mode.
    init(
        adaptiveLight lr: Double,
        _ lg: Double,
        _ lb: Double,
        alpha la: Double,
        dark dr: Double,
        _ dg: Double,
        _ db: Double,
        alpha da: Double = 0.10
    ) {
        self = Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = [
                    NSAppearance.Name.darkAqua,
                    .vibrantDark,
                    .accessibilityHighContrastDarkAqua,
                    .accessibilityHighContrastVibrantDark,
                ].contains(appearance.name)
                return isDark
                    ? NSColor(red: dr, green: dg, blue: db, alpha: da)
                    : NSColor(red: lr, green: lg, blue: lb, alpha: la)
            }
        )
    }
}
