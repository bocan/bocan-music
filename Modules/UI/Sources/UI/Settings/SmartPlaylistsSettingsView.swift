import Library
import SwiftUI

// MARK: - SmartPlaylistsSettingsView

/// Settings tab for smart-playlist behavior defaults.
public struct SmartPlaylistsSettingsView: View {
    @AppStorage(SmartPlaylistPreferences.defaultLiveUpdateKey)
    private var defaultLiveUpdate = true

    @AppStorage(SmartPlaylistPreferences.observeDebounceMillisecondsKey)
    private var observeDebounceMilliseconds = SmartPlaylistPreferences.defaultObserveDebounceMilliseconds

    @AppStorage(SmartPlaylistPreferences.randomRerollOnLaunchKey)
    private var randomRerollOnLaunch = false

    public init() {}

    public var body: some View {
        Form {
            Section(L10n.string("Defaults")) {
                Toggle(L10n.string("New smart playlists use live update"), isOn: self.$defaultLiveUpdate)
                    .help(L10n.string("If off, new smart playlists start in snapshot mode and only change on Refresh now"))
            }

            Section(L10n.string("Live Observation")) {
                Stepper(value: self.$observeDebounceMilliseconds, in: 0 ... 5000, step: 25) {
                    Text(localized: "Debounce window: \(self.observeDebounceMilliseconds) ms")
                }
                .help(L10n.string("Minimum delay before publishing live smart-playlist updates"))
            }

            Section(L10n.string("Random Sort")) {
                Toggle(L10n.string("Re-roll random order on app launch"), isOn: self.$randomRerollOnLaunch)
                    .help(L10n.string("When enabled, smart playlists sorted by Random use a per-launch seed"))
            }

            Section(L10n.string("Not Exposed Yet")) {
                Text(self.notExposedFooter)
                    .font(Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 440, minHeight: 320)
    }

    /// Multi-sentence copy as two sentence keys joined in code (#314).
    private var notExposedFooter: String {
        L10n.string("Mass auto-refresh interval for snapshot playlists is intentionally not user-configurable yet.")
            + " "
            + L10n.string("Snapshot mode remains on-demand (Refresh now) until a dedicated scheduler design lands.")
    }
}
