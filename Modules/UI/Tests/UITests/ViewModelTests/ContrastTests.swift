import AppKit
import Foundation
import SwiftUI
import Testing
@testable import UI

// MARK: - Source badge tints (ADR-092)

/// The five badge tints, so the contrast cases enumerate rather than repeat.
enum BadgeTintToken: String, CaseIterable {
    case codec, bitrate, sampleRate, bitDepth, channels

    var color: Color {
        switch self {
        case .codec:
            .badgeCodec

        case .bitrate:
            .badgeBitrate

        case .sampleRate:
            .badgeSampleRate

        case .bitDepth:
            .badgeBitDepth

        case .channels:
            .badgeChannels
        }
    }
}

// MARK: - ContrastTests

/// Verifies that every key semantic colour pair in Bòcan meets WCAG 2.1 AA
/// minimum contrast ratios in both light and dark appearance.
///
/// Normal text:      ≥ 4.5 : 1 (WCAG SC 1.4.3)
/// Non-text objects: ≥ 3.0 : 1 (WCAG SC 1.4.11)
///
/// Contrast is evaluated by resolving each adaptive `Color` through
/// `NSAppearance.performAsCurrentDrawingAppearance` to guarantee the correct
/// light/dark variant is sampled.
/// Main-actor: an `NSAppearance` lookup off the main thread can deadlock in
/// AppKit's system-appearance-proxy `dispatch_once` under the parallel test
/// runner (it wedged a full `make tests` run for hours on 2026-09-01, in
/// `+[NSSystemAppearanceProxy systemProxy]`). AppKit belongs on main anyway.
@MainActor
@Suite("Colour Contrast — WCAG 2.1 AA")
struct ContrastTests {
    // MARK: Helpers

    private func ratio(
        _ fg: Color,
        _ bg: Color,
        appearance: NSAppearance.Name
    ) -> Double {
        var result = 0.0
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            result = contrastRatio(fg, bg)
        }
        return result
    }

    // MARK: textPrimary — light mode

    @Test("textPrimary / bgPrimary light ≥ 4.5")
    func textPrimaryOnBgPrimaryLight() {
        let r = self.ratio(.textPrimary, .bgPrimary, appearance: .aqua)
        #expect(r >= 4.5, "Expected ≥ 4.5, got \(String(format: "%.2f", r))")
    }

    @Test("textPrimary / bgSecondary light ≥ 4.5")
    func textPrimaryOnBgSecondaryLight() {
        let r = self.ratio(.textPrimary, .bgSecondary, appearance: .aqua)
        #expect(r >= 4.5, "Expected ≥ 4.5, got \(String(format: "%.2f", r))")
    }

    // MARK: textPrimary — dark mode

    @Test("textPrimary / bgPrimary dark ≥ 4.5")
    func textPrimaryOnBgPrimaryDark() {
        let r = self.ratio(.textPrimary, .bgPrimary, appearance: .darkAqua)
        #expect(r >= 4.5, "Expected ≥ 4.5, got \(String(format: "%.2f", r))")
    }

    @Test("textPrimary / bgSecondary dark ≥ 4.5")
    func textPrimaryOnBgSecondaryDark() {
        let r = self.ratio(.textPrimary, .bgSecondary, appearance: .darkAqua)
        #expect(r >= 4.5, "Expected ≥ 4.5, got \(String(format: "%.2f", r))")
    }

    // MARK: textSecondary — light mode

    @Test("textSecondary / bgPrimary light ≥ 4.5")
    func textSecondaryOnBgPrimaryLight() {
        let r = self.ratio(.textSecondary, .bgPrimary, appearance: .aqua)
        #expect(r >= 4.5, "Expected ≥ 4.5, got \(String(format: "%.2f", r))")
    }

    @Test("textSecondary / bgSecondary light ≥ 4.5")
    func textSecondaryOnBgSecondaryLight() {
        let r = self.ratio(.textSecondary, .bgSecondary, appearance: .aqua)
        #expect(r >= 4.5, "Expected ≥ 4.5, got \(String(format: "%.2f", r))")
    }

    // MARK: textSecondary — dark mode

    @Test("textSecondary / bgPrimary dark ≥ 4.5")
    func textSecondaryOnBgPrimaryDark() {
        let r = self.ratio(.textSecondary, .bgPrimary, appearance: .darkAqua)
        #expect(r >= 4.5, "Expected ≥ 4.5, got \(String(format: "%.2f", r))")
    }

    @Test("textSecondary / bgSecondary dark ≥ 4.5")
    func textSecondaryOnBgSecondaryDark() {
        let r = self.ratio(.textSecondary, .bgSecondary, appearance: .darkAqua)
        #expect(r >= 4.5, "Expected ≥ 4.5, got \(String(format: "%.2f", r))")
    }

    // MARK: textTertiary — light mode

    @Test("textTertiary / bgPrimary light ≥ 4.5")
    func textTertiaryOnBgPrimaryLight() {
        let r = self.ratio(.textTertiary, .bgPrimary, appearance: .aqua)
        #expect(r >= 4.5, "Expected ≥ 4.5, got \(String(format: "%.2f", r))")
    }

    @Test("textTertiary / bgSecondary light ≥ 4.5")
    func textTertiaryOnBgSecondaryLight() {
        let r = self.ratio(.textTertiary, .bgSecondary, appearance: .aqua)
        #expect(r >= 4.5, "Expected ≥ 4.5, got \(String(format: "%.2f", r))")
    }

    // MARK: textTertiary — dark mode

    @Test("textTertiary / bgPrimary dark ≥ 4.5")
    func textTertiaryOnBgPrimaryDark() {
        let r = self.ratio(.textTertiary, .bgPrimary, appearance: .darkAqua)
        #expect(r >= 4.5, "Expected ≥ 4.5, got \(String(format: "%.2f", r))")
    }

    @Test("textTertiary / bgSecondary dark ≥ 4.5")
    func textTertiaryOnBgSecondaryDark() {
        let r = self.ratio(.textTertiary, .bgSecondary, appearance: .darkAqua)
        #expect(r >= 4.5, "Expected ≥ 4.5, got \(String(format: "%.2f", r))")
    }

    // MARK: ratingFill — non-text (≥ 3.0)

    @Test("ratingFill / bgPrimary light ≥ 3.0")
    func ratingFillOnBgPrimaryLight() {
        let r = self.ratio(.ratingFill, .bgPrimary, appearance: .aqua)
        #expect(r >= 3.0, "Expected ≥ 3.0, got \(String(format: "%.2f", r))")
    }

    @Test("ratingFill / bgPrimary dark ≥ 3.0")
    func ratingFillOnBgPrimaryDark() {
        let r = self.ratio(.ratingFill, .bgPrimary, appearance: .darkAqua)
        #expect(r >= 3.0, "Expected ≥ 3.0, got \(String(format: "%.2f", r))")
    }

    // MARK: lovedTint — non-text (≥ 3.0)

    @Test("lovedTint / bgPrimary light ≥ 3.0")
    func lovedTintOnBgPrimaryLight() {
        let r = self.ratio(.lovedTint, .bgPrimary, appearance: .aqua)
        #expect(r >= 3.0, "Expected ≥ 3.0, got \(String(format: "%.2f", r))")
    }

    @Test("lovedTint / bgPrimary dark ≥ 3.0")
    func lovedTintOnBgPrimaryDark() {
        let r = self.ratio(.lovedTint, .bgPrimary, appearance: .darkAqua)
        #expect(r >= 3.0, "Expected ≥ 3.0, got \(String(format: "%.2f", r))")
    }

    // MARK: accentColor — non-text (≥ 3.0)

    // Color.accentColor resolves to the system/user accent; in a headless test
    // environment this is typically the default macOS blue (#007AFF), which meets
    // the 3.0 threshold on both bgPrimary surfaces.

    @Test("accentColor / bgPrimary light >= 3.0")
    func accentColorOnBgPrimaryLight() {
        let r = self.ratio(.accentColor, .bgPrimary, appearance: .aqua)
        #expect(r >= 3.0, "Expected >= 3.0, got \(String(format: "%.2f", r))")
    }

    @Test("accentColor / bgPrimary dark >= 3.0")
    func accentColorOnBgPrimaryDark() {
        let r = self.ratio(.accentColor, .bgPrimary, appearance: .darkAqua)
        #expect(r >= 3.0, "Expected >= 3.0, got \(String(format: "%.2f", r))")
    }

    // MARK: warningTint — non-text (≥ 3.0)

    @Test("warningTint / bgPrimary light >= 3.0")
    func warningTintOnBgPrimaryLight() {
        let r = self.ratio(.warningTint, .bgPrimary, appearance: .aqua)
        #expect(r >= 3.0, "Expected >= 3.0, got \(String(format: "%.2f", r))")
    }

    @Test("warningTint / bgPrimary dark >= 3.0")
    func warningTintOnBgPrimaryDark() {
        let r = self.ratio(.warningTint, .bgPrimary, appearance: .darkAqua)
        #expect(r >= 3.0, "Expected >= 3.0, got \(String(format: "%.2f", r))")
    }

    // MARK: starTint — non-text (≥ 3.0)

    @Test("starTint / bgPrimary light >= 3.0")
    func starTintOnBgPrimaryLight() {
        let r = self.ratio(.starTint, .bgPrimary, appearance: .aqua)
        #expect(r >= 3.0, "Expected >= 3.0, got \(String(format: "%.2f", r))")
    }

    @Test("starTint / bgPrimary dark >= 3.0")
    func starTintOnBgPrimaryDark() {
        let r = self.ratio(.starTint, .bgPrimary, appearance: .darkAqua)
        #expect(r >= 3.0, "Expected >= 3.0, got \(String(format: "%.2f", r))")
    }

    // MARK: Will-o'-the-Wisp accent — non-text (≥ 3.0)

    @Test("willowispAccent / bgPrimary light >= 3.0")
    func willowispAccentOnBgPrimaryLight() {
        let r = self.ratio(.willowispAccent, .bgPrimary, appearance: .aqua)
        #expect(r >= 3.0, "Expected >= 3.0, got \(String(format: "%.2f", r))")
    }

    @Test("willowispAccent / bgPrimary dark >= 3.0")
    func willowispAccentOnBgPrimaryDark() {
        let r = self.ratio(.willowispAccent, .bgPrimary, appearance: .darkAqua)
        #expect(r >= 3.0, "Expected >= 3.0, got \(String(format: "%.2f", r))")
    }

    // MARK: Will-o'-the-Wisp alert — non-text (≥ 3.0)

    // Light variant deepened to #E84C2E so the coral clears 3:1 on warm-cream
    // bgPrimary; the spec's #FF6B57 only managed 2.65:1 there.

    @Test("willowispAlert / bgPrimary light >= 3.0")
    func willowispAlertOnBgPrimaryLight() {
        let r = self.ratio(.willowispAlert, .bgPrimary, appearance: .aqua)
        #expect(r >= 3.0, "Expected >= 3.0, got \(String(format: "%.2f", r))")
    }

    @Test("willowispAlert / bgPrimary dark >= 3.0")
    func willowispAlertOnBgPrimaryDark() {
        let r = self.ratio(.willowispAlert, .bgPrimary, appearance: .darkAqua)
        #expect(r >= 3.0, "Expected >= 3.0, got \(String(format: "%.2f", r))")
    }

    // MARK: Will-o'-the-Wisp highlight — dark-surface glow only (≥ 3.0)

    // A bright mint intended for dark surfaces; deliberately low contrast on
    // light surfaces, so it is asserted in dark appearance only.

    @Test("willowispHighlight / bgPrimary dark >= 3.0")
    func willowispHighlightOnBgPrimaryDark() {
        let r = self.ratio(.willowispHighlight, .bgPrimary, appearance: .darkAqua)
        #expect(r >= 3.0, "Expected >= 3.0, got \(String(format: "%.2f", r))")
    }

    // MARK: Source badge tints (ADR-092)

    // The border is a non-text component (≥ 3.0) against whichever surface the
    // play bar sits over; the label inside is normal text (≥ 4.5) on the tint
    // composited at `SourceBadge.fillOpacity` over that same surface.

    private func fillRatio(
        _ tint: Color,
        over background: Color,
        appearance: NSAppearance.Name
    ) -> Double {
        var result = 0.0
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let base = NSColor(background).usingColorSpace(.sRGB),
                  let top = NSColor(tint).usingColorSpace(.sRGB),
                  let fill = base.blended(withFraction: SourceBadge.fillOpacity, of: top) else { return }
            result = contrastRatio(.textPrimary, Color(nsColor: fill))
        }
        return result
    }

    @Test("badge tint borders clear 3.0 on both backgrounds, light", arguments: BadgeTintToken.allCases)
    func badgeTintBordersLight(tint: BadgeTintToken) {
        let onPrimary = self.ratio(tint.color, .bgPrimary, appearance: .aqua)
        let onSecondary = self.ratio(tint.color, .bgSecondary, appearance: .aqua)
        #expect(onPrimary >= 3.0, "\(tint.rawValue) on bgPrimary: got \(String(format: "%.2f", onPrimary))")
        #expect(onSecondary >= 3.0, "\(tint.rawValue) on bgSecondary: got \(String(format: "%.2f", onSecondary))")
    }

    @Test("badge tint borders clear 3.0 on both backgrounds, dark", arguments: BadgeTintToken.allCases)
    func badgeTintBordersDark(tint: BadgeTintToken) {
        let onPrimary = self.ratio(tint.color, .bgPrimary, appearance: .darkAqua)
        let onSecondary = self.ratio(tint.color, .bgSecondary, appearance: .darkAqua)
        #expect(onPrimary >= 3.0, "\(tint.rawValue) on bgPrimary: got \(String(format: "%.2f", onPrimary))")
        #expect(onSecondary >= 3.0, "\(tint.rawValue) on bgSecondary: got \(String(format: "%.2f", onSecondary))")
    }

    @Test("textPrimary clears 4.5 on every badge fill, light", arguments: BadgeTintToken.allCases)
    func badgeFillTextLight(tint: BadgeTintToken) {
        let onPrimary = self.fillRatio(tint.color, over: .bgPrimary, appearance: .aqua)
        let onSecondary = self.fillRatio(tint.color, over: .bgSecondary, appearance: .aqua)
        #expect(onPrimary >= 4.5, "\(tint.rawValue) fill on bgPrimary: got \(String(format: "%.2f", onPrimary))")
        #expect(onSecondary >= 4.5, "\(tint.rawValue) fill on bgSecondary: got \(String(format: "%.2f", onSecondary))")
    }

    @Test("textPrimary clears 4.5 on every badge fill, dark", arguments: BadgeTintToken.allCases)
    func badgeFillTextDark(tint: BadgeTintToken) {
        let onPrimary = self.fillRatio(tint.color, over: .bgPrimary, appearance: .darkAqua)
        let onSecondary = self.fillRatio(tint.color, over: .bgSecondary, appearance: .darkAqua)
        #expect(onPrimary >= 4.5, "\(tint.rawValue) fill on bgPrimary: got \(String(format: "%.2f", onPrimary))")
        #expect(onSecondary >= 4.5, "\(tint.rawValue) fill on bgSecondary: got \(String(format: "%.2f", onSecondary))")
    }

    // MARK: Accent palette checkmarks — non-text (≥ 3.0)

    @Test("AccentPalette labelColor achieves ≥ 3.0 on every swatch")
    func accentPaletteLabelColorPassesContrast() {
        // Skip "system" — the system accent is unknown at compile time.
        let namedAccents = AccentPalette.all.filter { $0.id != "system" }
        for accent in namedAccents {
            // Test in both appearances (the accent colors are not mode-adaptive).
            for appearanceName: NSAppearance.Name in [.aqua, .darkAqua] {
                var r = 0.0
                NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
                    r = contrastRatio(accent.labelColor, accent.color)
                }
                #expect(
                    r >= 3.0,
                    "'\(accent.id)' labelColor on accent bg: expected ≥ 3.0, got \(String(format: "%.2f", r)) (\(appearanceName.rawValue))"
                )
            }
        }
    }
}
