import Playback
import SwiftUI

// MARK: - SleepTimerMenu

/// A menu button for setting the sleep timer, shown in the NowPlayingStrip.
///
/// The label shows a moon icon + remaining time when the timer is active
/// (e.g. "☽ 28 m"), or just a moon icon when inactive.
public struct SleepTimerMenu: View {
    @ObservedObject public var vm: NowPlayingViewModel
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
            ? "Sleep timer active — \(self.formattedRemaining(self.vm.sleepTimerRemaining ?? 0)) remaining. Click to change."
            : "Sleep timer — automatically stop playback after a set time")
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityHint("Opens a menu of sleep timer presets. Choose a duration to automatically stop playback.")
    }

    // MARK: - Menu items

    @ViewBuilder
    private var menuItems: some View {
        // Active timer info header
        if let remaining = self.vm.sleepTimerRemaining {
            Text("Stops in \(self.formattedRemaining(remaining))")
                .foregroundStyle(Color.textSecondary)
            Divider()
        }

        Button("Off") {
            Task { await self.vm.setSleepTimer(minutes: nil) }
        }
        .disabled(self.vm.sleepTimerRemaining == nil)
        .help("Cancel the active sleep timer")

        Divider()

        ForEach(SleepTimerPreset.allCases.filter { $0 != .off }, id: \.displayName) { preset in
            if let minutes = preset.minutes {
                Button(preset.displayName) {
                    Task { await self.vm.setSleepTimer(minutes: minutes, fadeOut: self.vm.sleepTimerFadeOut) }
                }
                .help("Stop playback after \(preset.displayName)")
            }
        }

        Button("Custom…") {
            self.showCustomField = true
        }
        .help("Set a custom sleep timer duration")

        Divider()

        Toggle("Fade out in last 30 s", isOn: Binding(
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
        .help("Gradually reduce volume to silence over the final 30 seconds before the timer fires")
    }

    // MARK: - Label

    private var menuLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: "moon.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(self.vm.sleepTimerRemaining != nil ? Color.accentColor : Color.textTertiary)

            if let remaining = self.vm.sleepTimerRemaining {
                Text(self.shortRemaining(remaining))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - Helpers

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
            return "Sleep timer: \(self.formattedRemaining(remaining)) remaining"
        }
        return "Sleep timer: Off"
    }
}
