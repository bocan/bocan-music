import SwiftUI

// MARK: - NowPlayingPanelButtons

/// The auxiliary-panel buttons at the trailing end of the transport strip:
/// playback speed, sleep timer, the pending-scrobbles badge and Equaliser &
/// DSP. Split out of ``NowPlayingStrip`` so the strip stays under the
/// type-body cap; the state lives in the same preference keys the strip and
/// the menu bar already share. The strip has no slack at the window's minimum
/// width, so nothing new goes here: view toggles belong in the toolbar.
struct NowPlayingPanelButtons: View {
    var vm: NowPlayingViewModel
    /// Optional: only the main window injects one. When non-nil and there are
    /// pending scrobbles, the badge button is shown.
    var scrobbleSettingsVM: ScrobbleSettingsViewModel?

    @Environment(DSPViewModel.self) private var dsp: DSPViewModel
    @Environment(\.openWindow) private var openWindow
    /// Menu-to-strip signal (BocanCommands sets it); cleared at launch by BocanApp.
    @AppStorage("scrobble.showRecentSheet") private var showRecentScrobbles = false

    var body: some View {
        HStack(spacing: 14) {
            SpeedPickerView(vm: self.vm)

            SleepTimerMenu(vm: self.vm)

            if self.vm.pendingScrobbleCount > 0, self.scrobbleSettingsVM != nil {
                self.scrobblePendingButton
            }

            self.dspButton
        }
    }

    // MARK: - Buttons

    private var scrobblePendingButton: some View {
        Button {
            self.showRecentScrobbles = true
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .scaledSystemFont(size: 15, weight: .medium)
                .overlay(alignment: .topTrailing) {
                    ZStack {
                        Circle()
                            .fill(.background)
                            .frame(width: 9, height: 9)
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                    }
                    .offset(x: 5, y: -4)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.warningTint)
        .help(L10n.string("Scrobbles pending: \(self.vm.pendingScrobbleCount) — click to view"))
        .accessibilityLabel(L10n.string("Scrobbles pending"))
        .accessibilityValue(String(self.vm.pendingScrobbleCount))
        .accessibilityHint(L10n.string("Click to view recent scrobbles"))
        .accessibilityIdentifier(A11y.NowPlaying.scrobblePendingButton)
    }

    private var dspButton: some View {
        Button {
            self.openWindow(id: "dsp")
        } label: {
            Image(systemName: "slider.horizontal.3")
                .scaledSystemFont(size: 15, weight: .medium)
                .overlay(alignment: .topTrailing) {
                    if self.dsp.isEQActive || self.dsp.hasScopedPreset {
                        ZStack {
                            Circle()
                                .fill(.background)
                                .frame(width: 7, height: 7)
                            Circle()
                                .fill(self.dsp.hasScopedPreset ? Color.orange : Color.accentColor)
                                .frame(width: 5, height: 5)
                        }
                        .offset(x: 5, y: -4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            (self.dsp.isEQActive || self.dsp.hasScopedPreset)
                ? Color.accentColor : Color.textPrimary
        )
        .help(L10n.string("Equaliser & DSP (⌘⌥E)"))
        .accessibilityLabel(
            self.dsp.isEQActive || self.dsp.hasScopedPreset
                ? L10n.string("Equaliser & DSP — active") : L10n.string("Equaliser & DSP")
        )
        .accessibilityIdentifier(A11y.NowPlaying.dspButton)
    }
}
