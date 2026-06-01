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

    /// Window / page background.
    ///
    /// Light: #FAF8F5 — warm cream white (R > G > B adds subtle warmth;
    /// replaces the cold pure #FFFFFF).  Contrast against all text tiers ✓.
    /// Dark: #1C1C1E — unchanged.
    static let bgPrimary = Color(adaptiveLight: 0.980, 0.973, 0.961, dark: 0.110, 0.110, 0.118)

    /// Sidebar / secondary panels.
    ///
    /// Light: #F5F2EC — warm linen (replaces cold #F5F5F7).
    /// textSecondary ≈ 4.6 : 1, textTertiary ≈ 4.8 : 1 on this bg. ✓
    /// Dark: #2C2C2E — unchanged.
    static let bgSecondary = Color(adaptiveLight: 0.961, 0.949, 0.925, dark: 0.173, 0.173, 0.180)

    /// Cards / elevated surfaces.
    ///
    /// Light: #E9E6DF — warm stone (replaces cold #E8E8ED).
    /// Dark: #3A3A3C — unchanged.
    static let bgTertiary = Color(adaptiveLight: 0.914, 0.902, 0.875, dark: 0.227, 0.227, 0.235)

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
    /// Light: #6B6B6F — approx 5.0 : 1 on `bgPrimary` (#FAF8F5) and 4.8 : 1 on
    /// `bgSecondary` (#F5F2EC).  Previous value #AEAEB2 achieved only ~2.2 : 1 (fail).
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
    /// Light: #FF4700 — deepened further to maintain ≥ 3 : 1 on the warm cream
    /// `bgPrimary` (#FAF8F5, L ≈ 0.941).  Previous #FF5C00 achieved ~2.93 : 1
    /// on the warmed bg (fail).  New value ≈ 3.2 : 1 on warm bg. ✓
    ///
    /// Dark: #FF9F0A — unchanged; already achieves ~8.3 : 1 on dark `bgPrimary`.
    static let ratingFill = Color(adaptiveLight: 1.000, 0.280, 0.000, dark: 1.000, 0.624, 0.039)

    /// Heart / loved tint.  Light: #FF2D55  Dark: #FF375F
    static let lovedTint = Color(adaptiveLight: 1.000, 0.176, 0.333, dark: 1.000, 0.216, 0.373)

    /// Warning / attention tint (scrobble-pending indicator, etc.).
    ///
    /// Light: #CC5900 — deepened amber so the sRGB luminance is low enough to
    /// achieve ≥ 3 : 1 against warm-cream `bgPrimary` (#FAF8F5, L ≈ 0.941).
    /// Approx 3.6 : 1. ✓
    ///
    /// Dark: #FFB200 — bright golden amber; ≈ 9.9 : 1 on dark `bgPrimary`. ✓
    static let warningTint = Color(adaptiveLight: 0.800, 0.350, 0.000, dark: 1.000, 0.700, 0.000)

    /// Star / favourite tint.  Shares the `ratingFill` palette so that Subsonic
    /// stars and local rating stars render identically.
    static let starTint = ratingFill

    // MARK: - Will-o'-the-Wisp identity (issue #333)

    /// Signature spectral blue-green accent ("bòcan" = ghost; the marsh-light of
    /// Gaelic folklore).  Selectable from the accent picker; the heritage blue
    /// stays as the "System" swatch.
    ///
    /// Light: #1E9E8A — 3.14 : 1 on `bgPrimary` (passes WCAG 1.4.11 non-text /
    /// large-text 3 : 1; do NOT use for body text, which needs 4.5 : 1).
    /// Dark: #3FD6BC — 9.36 : 1 on dark `bgPrimary`. ✓
    ///
    /// Colour-blindness checked (Machado 2009, severity 1.0): stays separable
    /// from both its surface and `willowispAlert` across protan/deutan/tritan
    /// (worst-case ΔE 23, protanopia).
    static let willowispAccent = Color(adaptiveLight: 0.118, 0.620, 0.541, dark: 0.247, 0.839, 0.737)

    /// Will-o'-the-Wisp highlight / glow.  A bright mint intended for dark
    /// surfaces only (13.08 : 1 on dark `bgPrimary`); it is deliberately low
    /// contrast on light surfaces, so it is not audited against the light
    /// appearance.  Consumed by the spectral-glow behaviour in #334.
    static let willowispHighlight = Color(red: 0.612, green: 0.949, blue: 0.863)

    /// Will-o'-the-Wisp alert / coral.
    ///
    /// Light: #E84C2E — deepened from the direction's #FF6B57 (which was only
    /// 2.65 : 1 on warm-cream `bgPrimary`) to 3.60 : 1, clearing the 3 : 1
    /// graphical threshold.
    /// Dark: #FF6B57 — the spec value; 6.07 : 1 on dark `bgPrimary`. ✓
    static let willowispAlert = Color(adaptiveLight: 0.910, 0.298, 0.180, dark: 1.000, 0.420, 0.341)
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
