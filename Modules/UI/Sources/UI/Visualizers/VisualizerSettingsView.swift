import SwiftUI

// MARK: - VisualizerSettingsView

/// Settings tab for the visualizer: mode, FPS cap, sensitivity, palette, battery toggle.
public struct VisualizerSettingsView: View {
    @AppStorage("visualizer.mode") private var mode: VisualizerMode = .spectrumBars
    @AppStorage("visualizer.palette") private var palette: VisualizerPalette = .accent
    @AppStorage("visualizer.fpsCap") private var fpsCap: FPSCap = .sixty
    @AppStorage("visualizer.sensitivityRaw") private var sensitivityRaw = 1.0
    @AppStorage("visualizer.simplifyOnBattery") private var simplifyOnBattery = true

    public init() {}

    public var body: some View {
        Form {
            Section(L10n.string("Display")) {
                Picker(L10n.string("Mode"), selection: self.$mode) {
                    ForEach(VisualizerMode.allCases, id: \.self) { vizMode in
                        Label(vizMode.displayName, systemImage: vizMode.symbolName).tag(vizMode)
                    }
                }
                .pickerStyle(.radioGroup)

                Picker(L10n.string("Colour Palette"), selection: self.$palette) {
                    ForEach(VisualizerPalette.allCases, id: \.self) { pal in
                        Text(pal.displayName).tag(pal)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(L10n.string("Performance")) {
                Picker(L10n.string("Frame Rate"), selection: self.$fpsCap) {
                    ForEach(FPSCap.allCases, id: \.self) { cap in
                        Text(cap.displayName).tag(cap)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(L10n.string("Use simpler visualizer on battery"), isOn: self.$simplifyOnBattery)
                    .help(L10n.string("Caps to 30 fps and switches to Spectrum Bars when running on battery power"))
                    .accessibilityHint(L10n.string("Caps frame rate to 30 fps and switches to Spectrum Bars on battery"))
            }

            Section(L10n.string("Sensitivity")) {
                HStack {
                    Text(localized: "Input sensitivity")
                    Spacer()
                    Slider(value: self.$sensitivityRaw, in: 0.1 ... 3.0, step: 0.1)
                        .frame(width: 160)
                        .accessibilityLabel(L10n.string("Audio sensitivity"))
                        .accessibilityValue(String(format: "%.1f×", self.sensitivityRaw))
                    Text(String(format: "%.1g×", self.sensitivityRaw))
                        .monospacedDigit()
                        .frame(width: 36)
                }
                Button(L10n.string("Reset to 1×")) { self.sensitivityRaw = 1.0 }
                    .controlSize(.small)
                    .help(L10n.string("Reset sensitivity to default (1×)"))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.string("Visualizer"))
    }
}
