import SwiftUI

// MARK: - SourcesKind

/// Which kind of music server the Sources page is editing.
public enum SourcesKind: String, CaseIterable, Identifiable, Sendable {
    case subsonic
    case jellyfin

    public var id: String {
        self.rawValue
    }

    /// The kind a server id belongs to: Jellyfin when the id is one of
    /// `jellyfinServerIDs`, otherwise Subsonic. The router carries only an id, so
    /// the page asks the Jellyfin list instead of guessing.
    public static func kind(forServer id: UUID, jellyfinServerIDs: some Collection<UUID>) -> Self {
        jellyfinServerIDs.contains(id) ? .jellyfin : .subsonic
    }
}

// MARK: - SourcesSettingsPage

/// Settings, Sources: a kind switch above the Subsonic editor (unchanged) and the
/// Jellyfin editor (ADR-097).
///
/// The selected kind is `@State` in `SettingsScene`, seeded from the router's
/// pending server id. It is not an `@AppStorage`: a `RawRepresentable`
/// `@AppStorage` does not propagate across instances (docs/GOTCHAS.md). Without
/// a Jellyfin view model the switch is hidden and the page is the Subsonic one.
struct SourcesSettingsPage: View {
    @Binding var kind: SourcesKind
    let subsonicViewModel: SubsonicSettingsViewModel?
    let jellyfinViewModel: JellyfinSettingsViewModel?

    var body: some View {
        VStack(spacing: 0) {
            if self.jellyfinViewModel != nil {
                Picker(L10n.string("Server Type"), selection: self.$kind) {
                    Text(verbatim: "Subsonic / Navidrome").tag(SourcesKind.subsonic)
                    Text(verbatim: "Jellyfin").tag(SourcesKind.jellyfin)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)
                .help(L10n.string("Choose which kind of music server to set up."))
                .accessibilityLabel(L10n.string("Server Type"))
                .accessibilityIdentifier(A11y.JellyfinSettings.kindPicker)
                Divider()
            }
            self.editor
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch self.kind {
        case .subsonic:
            if let subsonicViewModel {
                SubsonicSettingsView(viewModel: subsonicViewModel)
            } else {
                self.unavailable
            }

        case .jellyfin:
            if let jellyfinViewModel {
                JellyfinSettingsView(viewModel: jellyfinViewModel)
            } else {
                self.unavailable
            }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            L10n.string("Sources Unavailable"),
            systemImage: "server.rack",
            description: Text(localized: "Music server sources can't be configured right now.")
        )
    }
}
