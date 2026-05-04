import SwiftUI

// MARK: - DSPSettingsView

/// Full DSP panel embedded in the Settings window.
///
/// Mirrors the tabbed layout of `DSPSheet` so users can configure the EQ,
/// effects, and ReplayGain from the standard Settings window (⌘,) without
/// needing the Now Playing strip's DSP sheet to be open.
public struct DSPSettingsView: View {
    @Environment(DSPViewModel.self) private var dsp: DSPViewModel

    public init() {}

    public var body: some View {
        TabView {
            EQView(vm: self.dsp)
                .tabItem { Label("Equaliser", systemImage: "slider.vertical.3") }

            DSPView(vm: self.dsp)
                .tabItem { Label("Effects", systemImage: "waveform") }

            ReplayGainSettingsView(vm: self.dsp)
                .tabItem { Label("ReplayGain", systemImage: "chart.bar.fill") }
        }
        .frame(minWidth: 560, minHeight: 480)
        .navigationTitle("DSP & EQ")
    }
}
