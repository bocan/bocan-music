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
        VStack(spacing: 0) {
            Picker("", selection: self.$section) {
                ForEach(DSPSection.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                Group {
                    switch self.section {
                    case .equaliser:
                        EQView(vm: self.dsp)

                    case .effects:
                        DSPView(vm: self.dsp)

                    case .replayGain:
                        ReplayGainSettingsView(vm: self.dsp)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 500)
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
