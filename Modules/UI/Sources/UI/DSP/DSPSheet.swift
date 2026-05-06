import SwiftUI

// MARK: - DSPSheet

/// Tabbed panel presenting EQ, effects, and ReplayGain settings.
///
/// Hosted in a floating `Window` scene (non-modal) so the user can tweak the EQ
/// while the track list and transport controls remain fully interactive.
public struct DSPSheet: View {
    @Bindable public var vm: DSPViewModel

    public init(vm: DSPViewModel) {
        self.vm = vm
    }

    public var body: some View {
        TabView {
            EQView(vm: self.vm)
                .tabItem { Label("Equaliser", systemImage: "slider.vertical.3") }

            DSPView(vm: self.vm)
                .tabItem { Label("Effects", systemImage: "waveform") }

            ReplayGainSettingsView(vm: self.vm)
                .tabItem { Label("ReplayGain", systemImage: "chart.bar.fill") }
        }
    }
}
