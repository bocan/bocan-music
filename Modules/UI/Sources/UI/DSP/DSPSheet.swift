import SwiftUI

// MARK: - DSPSheet

/// Tabbed panel sheet presenting EQ, effects, and ReplayGain settings.
///
/// Presented as a sheet from `NowPlayingStrip` when the user taps the EQ button.
/// Each tab wraps an existing DSP view; the sheet owns no additional state.
struct DSPSheet: View {
    @Bindable var vm: DSPViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            EQView(vm: self.vm)
                .tabItem { Label("Equaliser", systemImage: "slider.vertical.3") }

            DSPView(vm: self.vm)
                .tabItem { Label("Effects", systemImage: "waveform") }

            ReplayGainSettingsView(vm: self.vm)
                .tabItem { Label("ReplayGain", systemImage: "chart.bar.fill") }
        }
        .frame(minWidth: 560, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { self.dismiss() }
                    .keyboardShortcut(.return)
            }
        }
    }
}
