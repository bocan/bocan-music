import SwiftUI

// MARK: - DSPSettingsView

/// Wraps the full DSP panel in the Settings window.
public struct DSPSettingsView: View {
    @EnvironmentObject private var dsp: DSPViewModel

    public init() {}

    public var body: some View {
        DSPView(vm: self.dsp)
            .navigationTitle("DSP & EQ")
    }
}
