import AppKit
import SwiftUI

// MARK: - WCAG contrast helpers

/// Returns the WCAG 2.1 relative luminance of `color` as resolved in the
/// **current** NSAppearance drawing context.
///
/// Call this from within `NSAppearance.performAsCurrentDrawingAppearance` when
/// you need to evaluate a specific colour scheme.
public func relativeLuminance(_ color: Color) -> Double {
    // Resolve the adaptive Color to a concrete NSColor in sRGB.
    let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    func linearise(_ ch: Double) -> Double {
        ch <= 0.03928 ? ch / 12.92 : pow((ch + 0.055) / 1.055, 2.4)
    }
    let red = linearise(Double(ns.redComponent))
    let green = linearise(Double(ns.greenComponent))
    let blue = linearise(Double(ns.blueComponent))
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue
}

/// Returns the WCAG 2.1 contrast ratio between `fg` and `bg` as resolved in
/// the current NSAppearance drawing context.
public func contrastRatio(_ fg: Color, _ bg: Color) -> Double {
    let l1 = relativeLuminance(fg)
    let l2 = relativeLuminance(bg)
    let lighter = max(l1, l2)
    let darker = min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)
}

// MARK: - ContrastAuditView

/// DEBUG-only view that shows the WCAG 2.1 contrast ratio for every key
/// semantic colour pair in both light and dark appearance.
///
/// Pass: ≥ 4.5 : 1 for normal text, ≥ 3 : 1 for non-text UI components.
/// Accessible from the **Diagnostics** settings tab in debug builds.
public struct ContrastAuditView: View {
    // MARK: Pair definitions

    private struct AuditPair {
        let label: String
        let fg: Color
        let bg: Color
        /// Minimum ratio required (4.5 for normal text, 3.0 for non-text).
        let threshold: Double
    }

    private let pairs: [AuditPair] = [
        // Normal text pairs (WCAG AA: 4.5 : 1)
        AuditPair(label: "textPrimary / bgPrimary", fg: .textPrimary, bg: .bgPrimary, threshold: 4.5),
        AuditPair(label: "textPrimary / bgSecondary", fg: .textPrimary, bg: .bgSecondary, threshold: 4.5),
        AuditPair(label: "textSecondary / bgPrimary", fg: .textSecondary, bg: .bgPrimary, threshold: 4.5),
        AuditPair(label: "textSecondary / bgSecondary", fg: .textSecondary, bg: .bgSecondary, threshold: 4.5),
        AuditPair(label: "textTertiary / bgPrimary", fg: .textTertiary, bg: .bgPrimary, threshold: 4.5),
        AuditPair(label: "textTertiary / bgSecondary", fg: .textTertiary, bg: .bgSecondary, threshold: 4.5),
        // Non-text / graphical objects (WCAG 1.4.11: 3 : 1)
        AuditPair(label: "ratingFill / bgPrimary", fg: .ratingFill, bg: .bgPrimary, threshold: 3.0),
        AuditPair(label: "lovedTint / bgPrimary", fg: .lovedTint, bg: .bgPrimary, threshold: 3.0),
    ]

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WCAG 2.1 Colour Contrast")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            HStack(spacing: 0) {
                self.column(appearance: .init(named: .aqua), label: "Light")
                Divider()
                self.column(appearance: .init(named: .darkAqua), label: "Dark")
            }
        }
        .frame(minWidth: 640, minHeight: 320)
        .navigationTitle("Contrast Audit")
    }

    // MARK: Private

    private func column(appearance: NSAppearance?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(self.pairs, id: \.label) { pair in
                self.row(pair: pair, appearance: appearance)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func row(pair: AuditPair, appearance: NSAppearance?) -> some View {
        var ratio = 0.0
        appearance?.performAsCurrentDrawingAppearance {
            ratio = contrastRatio(pair.fg, pair.bg)
        }
        let passes = ratio >= pair.threshold
        let symbol = passes ? "checkmark.circle.fill" : "xmark.circle.fill"
        let tint: Color = passes ? .green : .red

        return HStack(spacing: 10) {
            // Colour swatch
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(pair.fg)
                .frame(width: 16, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.primary.opacity(0.2), lineWidth: 0.5)
                )
                .environment(\.colorScheme, appearance?.name == .darkAqua ? .dark : .light)

            Text(pair.label)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(String(format: "%.2f : 1", ratio))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 72, alignment: .trailing)

            Image(systemName: symbol)
                .foregroundStyle(tint)
                .imageScale(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }
}
