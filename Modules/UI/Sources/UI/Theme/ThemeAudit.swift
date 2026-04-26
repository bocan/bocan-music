import SwiftUI

// MARK: - ThemeAudit

/// Debug helper that renders swatches of every semantic colour in both light
/// and dark appearance, so the team can eyeball contrast without launching
/// Accessibility Inspector.
///
/// Enable via the Debug menu: **Debug > Show Theme Audit…**
public struct ThemeAuditView: View {
    private let swatches: [(name: String, color: Color)] = [
        ("bgPrimary", .bgPrimary),
        ("bgSecondary", .bgSecondary),
        ("bgTertiary", .bgTertiary),
        ("textPrimary", .textPrimary),
        ("textSecondary", .textSecondary),
        ("textTertiary", .textTertiary),
        ("accentColor", .accentColor),
    ]

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            self.swatchColumn(scheme: .light, label: "Light")
            Divider()
            self.swatchColumn(scheme: .dark, label: "Dark")
        }
        .frame(minWidth: 480, minHeight: 320)
        .navigationTitle("Theme Audit")
    }

    private func swatchColumn(scheme: ColorScheme, label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(self.swatches, id: \.name) { swatch in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(swatch.color)
                        .frame(width: 40, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                        )

                    Text(swatch.name)
                        .font(.system(.body, design: .monospaced))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .environment(\.colorScheme, scheme)
        .frame(maxWidth: .infinity)
    }
}
