import Persistence
import SwiftUI

// MARK: - PhoneSyncSettingsView

/// Settings -> Phone Sync (phase 22-8): enable toggle, sync-profile editor with a
/// size estimate, paired-devices list with Revoke, and "Pair a phone".
public struct PhoneSyncSettingsView: View {
    @ObservedObject private var viewModel: PhoneSyncViewModel

    public init(viewModel: PhoneSyncViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            self.enableSection
            if self.viewModel.enabled {
                self.profileSection
                self.pairedDevicesSection
                self.pairButton
            }
        }
        .formStyle(.grouped)
        .task { await self.viewModel.load() }
        .sheet(isPresented: self.pairingPresentedBinding) {
            PhoneSyncPairingSheet(viewModel: self.viewModel)
        }
    }

    // MARK: - Enable

    private var enableSection: some View {
        Section {
            Toggle(isOn: self.enabledBinding) {
                Text(localized: "Phone Sync")
            }
            .accessibilityLabel(L10n.string("Phone Sync"))
            if self.viewModel.enabled {
                Text(localized: "On. Discoverable on your local network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(localized: "Serve your library to a paired phone over your local network. One way, read only.")
        }
    }

    // MARK: - Sync profile

    private var profileSection: some View {
        Section(L10n.string("Sync Profile")) {
            Picker(L10n.string("What to sync"), selection: self.modeBinding) {
                Text(localized: "Everything").tag(PhoneSyncProfile.Mode.everything)
                Text(localized: "Choose playlists").tag(PhoneSyncProfile.Mode.choosePlaylists)
            }
            .pickerStyle(.segmented)

            if self.viewModel.profile.mode == .choosePlaylists {
                self.playlistPicker
            }

            Toggle(isOn: self.includePodcastsBinding) {
                Text(localized: "Include podcasts")
            }

            LabeledContent {
                Text(self.sizeEstimateText)
                    .foregroundStyle(.secondary)
            } label: {
                Text(localized: "Estimated size")
            }
            .accessibilityLabel(L10n.string("Estimated size"))
            .accessibilityValue(self.sizeEstimateText)
        }
    }

    @ViewBuilder
    private var playlistPicker: some View {
        if self.viewModel.playlists.isEmpty {
            Text(localized: "No playlists yet.")
                .foregroundStyle(.secondary)
        } else {
            // Native checkboxes: a trailing tick on a plain row was too easy to
            // miss, and a checkbox is the macOS idiom for a multi-select list.
            ForEach(self.viewModel.playlists) { playlist in
                Toggle(isOn: self.playlistBinding(playlist.id)) {
                    Text(playlist.name)
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel(playlist.name)
            }
        }
    }

    // MARK: - Paired devices

    private var pairedDevicesSection: some View {
        Section(L10n.string("Paired Phones")) {
            if self.viewModel.pairedDevices.isEmpty {
                Text(localized: "No paired phones yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(self.viewModel.pairedDevices, id: \.fingerprint) { device in
                    self.deviceRow(device)
                }
            }
        }
    }

    private func deviceRow(_ device: TrustedDevice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceName)
                Text(self.pairedDateText(device))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                Task { await self.viewModel.revoke(device) }
            } label: {
                Text(localized: "Revoke")
            }
            .accessibilityLabel(L10n.string("Revoke \(device.deviceName)"))
        }
    }

    // MARK: - Pair a phone

    private var pairButton: some View {
        Section {
            Button {
                Task { await self.viewModel.startPairing() }
            } label: {
                Label(L10n.string("Pair a Phone"), systemImage: "iphone.and.arrow.forward")
            }
        }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.viewModel.enabled },
            set: { on in Task { await self.viewModel.setEnabled(on) } }
        )
    }

    private var modeBinding: Binding<PhoneSyncProfile.Mode> {
        Binding(
            get: { self.viewModel.profile.mode },
            set: { mode in Task { await self.viewModel.setMode(mode) } }
        )
    }

    private var includePodcastsBinding: Binding<Bool> {
        Binding(
            get: { self.viewModel.profile.includePodcasts },
            set: { on in Task { await self.viewModel.setIncludePodcasts(on) } }
        )
    }

    private func playlistBinding(_ id: Int64) -> Binding<Bool> {
        Binding(
            get: { self.viewModel.isPlaylistSelected(id) },
            set: { on in Task { await self.viewModel.setPlaylistSelected(id, on) } }
        )
    }

    private var pairingPresentedBinding: Binding<Bool> {
        Binding(
            get: { self.viewModel.pairingSheet != nil },
            set: { presented in
                if !presented { Task { await self.viewModel.dismissPairing() } }
            }
        )
    }

    // MARK: - Formatting

    private var sizeEstimateText: String {
        let estimate = self.viewModel.sizeEstimate
        let bytes = ByteCountFormatter.string(fromByteCount: estimate.bytes, countStyle: .file)
        let size = L10n.string("About \(bytes)")
        let tracks = L10n.string("\(estimate.trackCount) tracks")
        guard estimate.episodeCount > 0 else { return "\(size), \(tracks)" }
        let episodes = L10n.string("\(estimate.episodeCount) episodes")
        return "\(size), \(tracks), \(episodes)"
    }

    private func pairedDateText(_ device: TrustedDevice) -> String {
        let date = Date(timeIntervalSince1970: device.pairedAt)
        let formatted = date.formatted(date: .abbreviated, time: .shortened)
        return L10n.string("Paired \(formatted)")
    }
}
