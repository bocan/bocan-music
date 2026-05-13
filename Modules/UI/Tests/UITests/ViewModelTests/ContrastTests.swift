import AppKit
import Foundation
import SwiftUI
import Testing
@testable import UI

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
