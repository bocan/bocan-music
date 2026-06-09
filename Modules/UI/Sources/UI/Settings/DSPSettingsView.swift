import SwiftUI

// MARK: - EQSettingsView

/// Equaliser settings tab.
///
/// `EQView` is a plain `VStack`, so we wrap it in `Form { }.formStyle(.grouped)`
/// to get the same safe-area inset handling that every other Settings tab
/// receives automatically from their own `Form { }.formStyle(.grouped)` body.
public struct EQSettingsView: View {
    @Environment(DSPViewModel.self) private var dsp: DSPViewModel

    public init() {}

    public var body: some View {
        Form {
            Section {
                EQView(vm: self.dsp)
                    .listRowSeparator(.hidden)
                    .listRowInsets(.init())
                    .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.string("Equaliser"))
    }
}

// MARK: - EffectsSettingsView

/// Effects settings tab (bass boost, crossfeed, stereo width, crossfade).
public struct EffectsSettingsView: View {
    @Environment(DSPViewModel.self) private var dsp: DSPViewModel

    public init() {}

    public var body: some View {
        DSPView(vm: self.dsp)
            .navigationTitle(L10n.string("Effects"))
    }
}

// MARK: - ReplayGainSettingsTabView

/// ReplayGain settings tab.
public struct ReplayGainSettingsTabView: View {
    @Environment(DSPViewModel.self) private var dsp: DSPViewModel

    public init() {}

    public var body: some View {
        ReplayGainSettingsView(vm: self.dsp)
            .navigationTitle(L10n.string("ReplayGain"))
    }
}
