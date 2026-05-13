import SwiftUI

// MARK: - DSPSettingsView

/// Full DSP panel embedded in the Settings window.
///
/// Uses a segmented picker (not a nested `TabView`) to switch between the three
/// sub-sections.  A nested `TabView` inside the macOS 26 Settings `TabView`
/// causes inner tab items to leak into the outer toolbar, producing duplicates
/// and an inaccessible overflow area.
public struct DSPSettingsView: View {
    @Environment(DSPViewModel.self) private var dsp: DSPViewModel
    @State private var section: DSPSection = .equaliser

    public init() {}

    public var body: some View {
        Group {
            switch self.section {
            case .equaliser:
                EQView(vm: self.dsp)
                    .frame(maxWidth: .infinity)

            case .effects:
                DSPView(vm: self.dsp)

            case .replayGain:
                ReplayGainSettingsView(vm: self.dsp)
            }
        }
        .frame(minWidth: 560, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: self.$section) {
                    ForEach(DSPSection.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(minWidth: 280)
                .accessibilityLabel("DSP section")
                .help(
                    "Switch between Equaliser (10-band EQ),"
                        + " Effects (bass boost, stereo width), and ReplayGain."
                )
            }
        }
        .navigationTitle("DSP & EQ")
    }
}

// MARK: - DSPSection

private enum DSPSection: String, CaseIterable, Identifiable {
    case equaliser, effects, replayGain

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .equaliser:
            "Equaliser"

        case .effects:
            "Effects"

        case .replayGain:
            "ReplayGain"
        }
    }
}
