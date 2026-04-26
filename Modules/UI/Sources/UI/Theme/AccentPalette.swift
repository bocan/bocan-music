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
    }

    /// All available accent colours, in display order.
    public static let all: [AccentColor] = [
        .init(id: "system", displayName: "System", color: .accentColor),
        .init(id: "blue", displayName: "Blue", color: Color(red: 0.0, green: 0.48, blue: 1.0)),
        .init(id: "purple", displayName: "Purple", color: Color(red: 0.59, green: 0.26, blue: 0.95)),
        .init(id: "pink", displayName: "Pink", color: Color(red: 1.0, green: 0.18, blue: 0.38)),
        .init(id: "red", displayName: "Red", color: Color(red: 1.0, green: 0.23, blue: 0.19)),
        .init(id: "orange", displayName: "Orange", color: Color(red: 1.0, green: 0.58, blue: 0.0)),
        .init(id: "yellow", displayName: "Yellow", color: Color(red: 1.0, green: 0.80, blue: 0.0)),
        .init(id: "green", displayName: "Green", color: Color(red: 0.20, green: 0.78, blue: 0.35)),
        .init(id: "teal", displayName: "Teal", color: Color(red: 0.19, green: 0.68, blue: 0.76)),
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
                                .foregroundStyle(.white)
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
