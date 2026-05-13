import SwiftUI

// MARK: - AccentPalette

/// Eight curated accent colours plus "System" (uses the OS accent preference).
///
/// Store the selection in `@AppStorage("appearance.accentColor")` as the
/// `AccentColor.id` string, then apply via `.tint(AccentPalette.color(for:))`.
public enum AccentPalette {
    // MARK: - Colours

    public struct AccentColor: Identifiable, Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let color: Color
        /// Colour to use for a label (e.g. the selection checkmark) drawn on top of
        /// `color`.  Precomputed so contrast is always ≥ 3 : 1 (WCAG 1.4.11 non-text).
        public let labelColor: Color
    }

    /// All available accent colours, in display order.
    ///
    /// `labelColor` rule per entry:
    /// - `.white`  — accent relative luminance L ≤ 0.30; white ≥ 3 : 1 on that bg.
    /// - `.black`  — accent relative luminance L  > 0.30; white would fall below 3 : 1.
    ///
    /// Luminance reference values (sRGB WCAG formula):
    ///   system  ≈ variable (blue default ~0.21) → white
    ///   blue    ≈ 0.21 → white  (4.0 : 1)
    ///   purple  ≈ 0.17 → white  (4.8 : 1)
    ///   pink    ≈ 0.24 → white  (3.6 : 1)
    ///   red     ≈ 0.25 → white  (3.6 : 1)
    ///   orange  ≈ 0.42 → black  (white = 2.2 : 1 ✗  black = 7.6 : 1 ✓)
    ///   yellow  ≈ 0.64 → black  (white = 1.5 : 1 ✗  black = 11.1 : 1 ✓)
    ///   green   ≈ 0.42 → black  (white = 2.2 : 1 ✗  black = 7.6 : 1 ✓)
    ///   teal    ≈ 0.35 → black  (white = 2.7 : 1 ✗  black = 6.3 : 1 ✓)
    public static let all: [AccentColor] = [
        .init(id: "system", displayName: "System", color: .accentColor, labelColor: .white),
        .init(id: "blue", displayName: "Blue", color: Color(red: 0.0, green: 0.48, blue: 1.0), labelColor: .white),
        .init(id: "purple", displayName: "Purple", color: Color(red: 0.59, green: 0.26, blue: 0.95), labelColor: .white),
        .init(id: "pink", displayName: "Pink", color: Color(red: 1.0, green: 0.18, blue: 0.38), labelColor: .white),
        .init(id: "red", displayName: "Red", color: Color(red: 1.0, green: 0.23, blue: 0.19), labelColor: .white),
        .init(id: "orange", displayName: "Orange", color: Color(red: 1.0, green: 0.58, blue: 0.0), labelColor: .black),
        .init(id: "yellow", displayName: "Yellow", color: Color(red: 1.0, green: 0.80, blue: 0.0), labelColor: .black),
        .init(id: "green", displayName: "Green", color: Color(red: 0.20, green: 0.78, blue: 0.35), labelColor: .black),
        .init(id: "teal", displayName: "Teal", color: Color(red: 0.19, green: 0.68, blue: 0.76), labelColor: .black),
    ]

    /// Returns the `Color` for the given accent ID, falling back to `.accentColor`.
    public static func color(for id: String) -> Color {
        self.all.first { $0.id == id }?.color ?? .accentColor
    }
}

// MARK: - AccentPaletteView

/// A grid of swatch buttons for picking an accent colour in Settings.
public struct AccentPaletteView: View {
    @Binding public var selection: String

    public init(selection: Binding<String>) {
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 10) {
            ForEach(AccentPalette.all) { accent in
                Button {
                    self.selection = accent.id
                } label: {
                    ZStack {
                        Circle()
                            .fill(accent.color)
                            .frame(width: 26, height: 26)

                        if self.selection == accent.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(accent.labelColor)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(accent.displayName)
                .accessibilityLabel(accent.displayName)
                .accessibilityAddTraits(self.selection == accent.id ? .isSelected : [])
            }
        }
    }
}
