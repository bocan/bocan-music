import AudioEngine
import Persistence
import SwiftUI

// MARK: - PhoneSyncSettingsView

/// Settings -> Phone Sync (ADR-068): enable toggle, paired-devices list with
/// Revoke and "Pair a Phone", then the sync-profile editor with a size estimate.
/// Pairing sits above the profile because it is the first thing a new user needs;
/// the profile editor (and its playlist picker) can grow tall enough to push
/// anything below it out of view.
public struct PhoneSyncSettingsView: View {
    @ObservedObject private var viewModel: PhoneSyncViewModel

    public init(viewModel: PhoneSyncViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            self.enableSection
            if self.viewModel.enabled {
                self.pairedDevicesSection
                self.pairButton
                self.profileSection
                self.qualitySection
            }
        }
        .formStyle(.grouped)
        .task {
            await self.viewModel.load()
            // Both watchers run for the pane's lifetime; concurrent, since
            // each awaits its stream until the task is cancelled.
            async let hashing: Void = self.viewModel.watchHashingProgress()
            async let preparing: Void = self.viewModel.watchTranscodeProgress()
            _ = await (hashing, preparing)
        }
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
            .accessibilityIdentifier(A11y.SettingsIDs.phoneSyncToggle)
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
            .accessibilityIdentifier(A11y.SettingsIDs.phoneSyncMode)

            if self.viewModel.profile.mode == .choosePlaylists {
                self.playlistPicker
            }

            Toggle(isOn: self.includePodcastsBinding) {
                Text(localized: "Include podcasts")
            }
            .accessibilityIdentifier(A11y.SettingsIDs.phoneSyncIncludePodcasts)

            LabeledContent {
                Text(self.sizeEstimateText)
                    .foregroundStyle(.secondary)
            } label: {
                Text(localized: "Estimated size")
            }
            .accessibilityLabel(L10n.string("Estimated size"))
            .accessibilityValue(self.sizeEstimateText)

            self.readinessRow
        }
    }

    /// How much of the library carries the content hash Phone Sync serves by;
    /// while the launch backfill is still running, this is the answer to "why
    /// does my phone only see part of my library". Hidden until the
    /// observation's first emission.
    @ViewBuilder
    private var readinessRow: some View {
        if let progress = self.viewModel.hashingProgress {
            LabeledContent {
                Text(self.readinessText(progress))
                    .foregroundStyle(.secondary)
            } label: {
                Text(localized: "Ready to sync")
            }
            .accessibilityLabel(L10n.string("Ready to sync"))
            .accessibilityValue(self.readinessText(progress))
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
                .accessibilityIdentifier(A11y.SettingsIDs.phoneSyncPlaylistToggle)
            }
        }
    }

    // MARK: - Paired devices

    private var pairedDevicesSection: some View {
        Section(L10n.string("Paired Phones")) {
            if self.viewModel.pairedDevices.isEmpty {
                self.pairingCallToAction
            } else {
                ForEach(self.viewModel.pairedDevices, id: \.fingerprint) { device in
                    self.deviceRow(device)
                }
            }
        }
    }

    /// First-run empty state: no phone is paired yet, so the section itself is
    /// the call to action, with the prominent pairing button inside it. The
    /// standalone button section below is hidden in this state (a second
    /// button would compete with this one).
    private var pairingCallToAction: some View {
        ContentUnavailableView {
            Label(L10n.string("No Phones Paired"), systemImage: "iphone.gen3")
        } description: {
            Text(localized: "Pair your phone to start syncing your library.")
        } actions: {
            Button {
                Task { await self.viewModel.startPairing() }
            } label: {
                Label(L10n.string("Pair a Phone"), systemImage: "iphone.and.arrow.forward")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(A11y.SettingsIDs.pairPhone)
        }
        // Form rows lay content out leading-aligned and the view hugs its
        // content, which parked the whole block left of the card's centre.
        .frame(maxWidth: .infinity)
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

    /// The standalone "pair another" button, shown only once at least one
    /// phone is paired; the empty state carries its own prominent button.
    @ViewBuilder
    private var pairButton: some View {
        if !self.viewModel.pairedDevices.isEmpty {
            Section {
                Button {
                    Task { await self.viewModel.startPairing() }
                } label: {
                    Label(L10n.string("Pair a Phone"), systemImage: "iphone.and.arrow.forward")
                }
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

    // MARK: - Quality (ADR-088)

    private var qualitySection: some View {
        Section {
            Picker(L10n.string("Quality on Phone"), selection: self.presetBinding) {
                ForEach(Self.presetOptions, id: \.self) { option in
                    Text(self.rungRowText(option)).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier(A11y.SettingsIDs.phoneSyncQuality)

            if self.viewModel.transcode.preset != nil {
                Toggle(isOn: self.keepBinding) {
                    Text(localized: "Keep prepared copies for faster re-syncs")
                }
                .accessibilityIdentifier(A11y.SettingsIDs.phoneSyncKeepArtifacts)
                self.preparingRow
            }
        } header: {
            Text(localized: "Quality on Phone")
        } footer: {
            Text(localized: "Files above the chosen quality are converted for the phone; smaller files sync unchanged.")
        }
    }

    /// Visible once the progress observation emits under an active preset;
    /// mirrors the readiness row's shape.
    @ViewBuilder
    private var preparingRow: some View {
        if let progress = self.viewModel.transcodeProgress {
            LabeledContent {
                Text(self.preparingText(progress))
                    .foregroundStyle(.secondary)
            } label: {
                Text(localized: "Preparing for sync")
            }
            .accessibilityLabel(L10n.string("Preparing for sync"))
            .accessibilityValue(self.preparingText(progress))
        }
    }

    private static let presetOptions: [TranscodePreset?] = [nil] + TranscodePreset.allCases

    /// UI-side display mapping; preset raw values stay English identifiers.
    private func presetName(_ preset: TranscodePreset?) -> String {
        switch preset {
        case nil:
            L10n.string("Original quality")

        case .mp3320:
            L10n.string("MP3 320 kbps")

        case .mp3256:
            L10n.string("MP3 256 kbps")

        case .opus192:
            L10n.string("Opus 192 kbps")

        case .opus128:
            L10n.string("Opus 128 kbps")
        }
    }

    private func rungRowText(_ preset: TranscodePreset?) -> String {
        let name = self.presetName(preset)
        guard let estimate = self.viewModel.rungEstimates[preset], estimate.bytes > 0 else { return name }
        let bytes = estimate.bytes.formatted(.byteCount(style: .file))
        return preset == nil
            ? L10n.string("\(name) · \(bytes)")
            : L10n.string("\(name) · about \(bytes)")
    }

    private func preparingText(_ progress: PhoneSyncTranscodeProgress) -> String {
        guard !progress.isComplete else { return L10n.string("All songs prepared") }
        return L10n.string("\(progress.prepared) of \(progress.total) songs")
    }

    private var presetBinding: Binding<TranscodePreset?> {
        Binding(
            get: { self.viewModel.transcode.preset },
            set: { preset in Task { await self.viewModel.setTranscodePreset(preset) } }
        )
    }

    private var keepBinding: Binding<Bool> {
        Binding(
            get: { self.viewModel.transcode.keepArtifacts },
            set: { keep in Task { await self.viewModel.setKeepArtifacts(keep) } }
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

    private func readinessText(_ progress: ContentHashProgress) -> String {
        guard !progress.isComplete else { return L10n.string("All tracks") }
        return L10n.string("\(progress.ready) of \(progress.total) tracks, still preparing")
    }

    private func pairedDateText(_ device: TrustedDevice) -> String {
        let date = Date(timeIntervalSince1970: device.pairedAt)
        let formatted = date.formatted(date: .abbreviated, time: .shortened)
        return L10n.string("Paired \(formatted)")
    }
}
