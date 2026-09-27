import Playback
import SwiftUI

// MARK: - SleepTimerMenu

/// A menu button for setting the sleep timer, shown in the NowPlayingStrip.
///
/// The label shows a moon icon + remaining time when the timer is active
/// (e.g. "☽ 28 m"), or just a moon icon when inactive.
public struct SleepTimerMenu: View {
    public var vm: NowPlayingViewModel
    @State private var customMinutes = 30
    @State private var showCustomField = false

    public init(vm: NowPlayingViewModel) {
        self.vm = vm
    }

    public var body: some View {
        Menu {
            self.menuItems
        } label: {
            self.menuLabel
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(self.vm.sleepTimerRemaining != nil
            ? L10n.string("Sleep timer active — \(self.formattedRemaining(self.vm.sleepTimerRemaining ?? 0)) remaining. Click to change.")
            : L10n.string("Sleep timer — automatically stop playback after a set time"))
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityHint(
            L10n.string("Opens a menu of sleep timer presets. Choose a duration to automatically stop playback.")
        )
        .accessibilityIdentifier(A11y.NowPlaying.sleepTimer)
        .popover(isPresented: self.$showCustomField, arrowEdge: .top) {
            self.customDurationPopover
        }
    }

    // MARK: - Custom duration popover

    private var customDurationPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized: "Custom Sleep Timer")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 8) {
                Stepper(value: self.$customMinutes, in: 1 ... 480) {
                    HStack(spacing: 4) {
                        TextField(L10n.string("Minutes"), value: self.$customMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel(L10n.string("Minutes"))
                        Text(self.customMinutes == 1 ? L10n.string("minute") : L10n.string("minutes"))
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                .help(L10n.string("Set the number of minutes (1–480) before playback stops"))
            }

            HStack {
                Spacer()
                Button(L10n.string("Cancel"), role: .cancel) {
                    self.showCustomField = false
                }
                .keyboardShortcut(.cancelAction)
                .help(L10n.string("Close without changing the sleep timer"))

                Button(L10n.string("Start")) {
                    let mins = max(1, min(480, self.customMinutes))
                    Task {
                        await self.vm.setSleepTimer(minutes: mins, fadeOut: self.vm.sleepTimerFadeOut)
                    }
                    self.showCustomField = false
                }
                .keyboardShortcut(.defaultAction)
                .help(L10n.string("Start the sleep timer with the chosen duration"))
            }
        }
        .padding(16)
        .frame(minWidth: 260)
    }

    // MARK: - Menu items

    @ViewBuilder
    private var menuItems: some View {
        // Active timer info header
        if let remaining = self.vm.sleepTimerRemaining {
            Text(localized: "Stops in \(self.formattedRemaining(remaining))")
                .foregroundStyle(Color.textSecondary)
            Divider()
        }

        Button(L10n.string("Off")) {
            Task { await self.vm.setSleepTimer(minutes: nil) }
        }
        .disabled(self.vm.sleepTimerRemaining == nil)
        .help(L10n.string("Cancel the active sleep timer"))

        Divider()

        ForEach(SleepTimerPreset.allCases.filter { $0 != .off }, id: \.displayName) { preset in
            if let minutes = preset.minutes {
                Button(Self.presetLabel(preset)) {
                    Task { await self.vm.setSleepTimer(minutes: minutes, fadeOut: self.vm.sleepTimerFadeOut) }
                }
                .help(L10n.string("Stop playback after \(Self.presetLabel(preset))"))
            }
        }

        Button(L10n.string("Custom…")) {
            self.showCustomField = true
        }
        .help(L10n.string("Set a custom sleep timer duration"))

        Divider()

        Toggle(L10n.string("Fade out in last 30 s"), isOn: Binding(
            get: { self.vm.sleepTimerFadeOut },
            set: { newVal in
                Task {
                    if let rem = self.vm.sleepTimerRemaining {
                        let mins = Int(rem / 60) + 1
                        await self.vm.setSleepTimer(minutes: mins, fadeOut: newVal)
                    } else {
                        // Just remember the preference; timer isn't active
                        await self.vm.setSleepTimer(minutes: nil, fadeOut: newVal)
                    }
                }
            }
        ))
        .help(L10n.string("Gradually reduce volume to silence over the final 30 seconds before the timer fires"))
    }

    // MARK: - Label

    private var menuLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: "moon.fill")
                .scaledSystemFont(size: 13, weight: .medium)
                .foregroundStyle(self.vm.sleepTimerRemaining != nil ? Color.accentColor : Color.textTertiary)

            if let remaining = self.vm.sleepTimerRemaining {
                Text(self.shortRemaining(remaining))
                    .scaledSystemFont(size: 11, weight: .medium, design: .monospaced)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - Helpers

    /// UI-side labels for ``SleepTimerPreset``. The Playback-owned
    /// `displayName` raw values stay English; translation happens here.
    private static func presetLabel(_ preset: SleepTimerPreset) -> String {
        switch preset {
        case .off:
            L10n.string("Off")

        case .minutes15:
            L10n.string("15 min")

        case .minutes30:
            L10n.string("30 min")

        case .minutes45:
            L10n.string("45 min")

        case .minutes60:
            L10n.string("1 hr")

        case .minutes90:
            L10n.string("1 hr 30 min")

        case .minutes120:
            L10n.string("2 hr")

        case let .custom(minutes):
            L10n.string("\(minutes) min")
        }
    }

    private func formattedRemaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d h %02d m", hours, mins)
        } else if mins > 0 {
            return String(format: "%d m %02d s", mins, secs)
        } else {
            return "\(secs) s"
        }
    }

    private func shortRemaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let mins = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(mins > 0 ? " \(mins)m" : "")"
        } else {
            return "\(mins > 0 ? mins : 1)m"
        }
    }

    private var accessibilityLabel: String {
        if let remaining = self.vm.sleepTimerRemaining {
            return L10n.string("Sleep timer: \(self.formattedRemaining(remaining)) remaining")
        }
        return L10n.string("Sleep timer: Off")
    }
}
