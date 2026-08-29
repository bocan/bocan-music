import SwiftUI

// MARK: - DeepDiveDisabledView

/// What a Deep Dive tab shows while the feature is off (#413): what it would
/// do, what it would send, and a button to the Settings control.
struct DeepDiveDisabledView: View {
    @Environment(\.settingsRouter) private var settingsRouter
    @Environment(\.openSettings) private var openSettings

    /// Two sentence keys joined in code so each translates independently (#314).
    private var privacyNote: String {
        L10n.string("When it is on, Bòcan sends MusicBrainz identifiers (or an artist's name) to MusicBrainz and Wikipedia.")
            + " " + L10n.string("Nothing is sent while it is off.")
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(Color.textTertiary)
                .accessibilityHidden(true)
            Text(localized: "Deep Dive is off")
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
            Text(localized: "Deep Dive adds a report to Get Info for artists, albums and songs, built from MusicBrainz and Wikipedia.")
                .font(Typography.body)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
            Text(self.privacyNote)
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
                .multilineTextAlignment(.center)
            Button(L10n.string("Open Deep Dive Settings…")) {
                self.settingsRouter?.open(.library)
                self.openSettings()
            }
            .help(L10n.string("Opens Settings > Library, where Deep Dive can be turned on"))
            .accessibilityIdentifier(A11y.DeepDive.openSettingsButton)
        }
        .frame(maxWidth: 420)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
