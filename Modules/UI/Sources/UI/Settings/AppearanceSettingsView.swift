import SwiftUI

// MARK: - AppearanceSettingsView

public struct AppearanceSettingsView: View {
    @AppStorage("appearance.colorScheme") private var colorScheme = "system"
    @AppStorage("appearance.accentColor") private var accentColor = "system"
    @AppStorage("appearance.rowDensity") private var rowDensity = "regular"

    public init() {}

    public var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: self.$colorScheme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .help("System follows your macOS system appearance setting. Light or Dark overrides it for Bòcan only.")
            }

            Section("Accent Colour") {
                AccentPaletteView(selection: self.$accentColor)
            }

            Section("Layout") {
                Picker("Row density", selection: self.$rowDensity) {
                    Text("Compact").tag("compact")
                    Text("Regular").tag("regular")
                    Text("Spacious").tag("spacious")
                }
                .pickerStyle(.segmented)
                .help("Compact fits more tracks on screen; Spacious is easier to read at a distance.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }
}
