import SwiftUI

// MARK: - AppearanceSettingsView

public struct AppearanceSettingsView: View {
    @AppStorage("appearance.colorScheme") private var colorScheme = "system"
    @AppStorage("appearance.accentColor") private var accentColor = "system"
    @AppStorage("appearance.rowDensity") private var rowDensity = "spacious"

    public init() {}

    public var body: some View {
        Form {
            Section(L10n.string("Theme")) {
                Picker(L10n.string("Appearance"), selection: self.$colorScheme) {
                    Text(localized: "System").tag("system")
                    Text(localized: "Light").tag("light")
                    Text(localized: "Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .help(L10n.string(
                    "System follows your macOS system appearance setting. Light or Dark overrides it for Bòcan only."
                ))
            }

            Section(L10n.string("Accent Colour")) {
                AccentPaletteView(selection: self.$accentColor)
            }

            Section(L10n.string("Layout")) {
                Picker(L10n.string("Row density"), selection: self.$rowDensity) {
                    Text(localized: "Compact").tag("compact")
                    Text(localized: "Regular").tag("regular")
                    Text(localized: "Spacious").tag("spacious")
                }
                .pickerStyle(.segmented)
                .help(L10n.string("Compact fits more tracks on screen; Spacious is easier to read at a distance."))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.string("Appearance"))
    }
}
