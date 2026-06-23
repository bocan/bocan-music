import AppKit
import SwiftUI

// MARK: - NowPlayingStrip

/// The 72pt-tall transport bar anchored at the bottom of every main view.
///
/// Shows current track artwork, title/artist/album, play/pause and scrubber,
/// and a volume slider.
public struct NowPlayingStrip: View {
    public var vm: NowPlayingViewModel
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(DSPViewModel.self) private var dsp: DSPViewModel

    /// While dragging the scrubber, the fraction is held locally so the Slider
    /// doesn't fight live `vm.position` updates; seeking happens on release.
    @AppStorage("appearance.accentColor") private var accentColorKey = "system"
    @State private var scrubDragFraction: Double?
    /// Menu-to-strip signal (BocanCommands sets it); cleared at launch by BocanApp.
    @AppStorage("scrobble.showRecentSheet") private var showRecentScrobbles = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Optional — only the main window injects a `ScrobbleSettingsViewModel`.
    /// When non-nil and `vm.pendingScrobbleCount > 0`, a pending-scrobbles
    /// indicator is shown in the panel-buttons area.
    var scrobbleSettingsVM: ScrobbleSettingsViewModel?

    public init(vm: NowPlayingViewModel, scrobbleSettingsVM: ScrobbleSettingsViewModel? = nil) {
        self.vm = vm
        self.scrobbleSettingsVM = scrobbleSettingsVM
    }

    public var body: some View {
        HStack(spacing: 12) {
            self.artwork
                .id(self.vm.nowPlayingTrackID)
                .transition(self.reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            self.trackInfo
                .id(self.vm.nowPlayingTrackID)
                .transition(self.reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            Spacer(minLength: 16)
            self.transport
            Spacer(minLength: 16)
            self.volumeAndScrubber
            Spacer(minLength: 16)
            Divider()
                .frame(height: 32)
                .padding(.horizontal, 4)
            self.panelButtons
        }
        .animation(.easeInOut(duration: 0.25), value: self.vm.nowPlayingTrackID)
        .frame(height: Theme.nowPlayingStripHeight)
        .padding(.horizontal, 16)
        .adaptiveMaterial()
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.NowPlaying.strip)
        .sheet(isPresented: self.$showRecentScrobbles) {
            if let ssvm = self.scrobbleSettingsVM {
                RecentScrobblesView(viewModel: ssvm)
            }
        }
    }

    // MARK: - Sub-views

    private var artwork: some View {
        Button {
            if self.vm.isPodcast, let id = self.vm.podcastID {
                Task { await self.library.selectDestination(.podcastShow(id)) }
            } else {
                Task { await self.library.goToCurrentAlbum() }
            }
        } label: {
            Group {
                if let img = vm.artwork {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.artworkCornerRadius, style: .continuous))
                        .accessibilityHidden(true)
                } else {
                    GradientPlaceholder(seed: 0)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.artworkCornerRadius, style: .continuous))
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(self.vm.isPodcast ? self.vm.podcastID == nil : self.vm.nowPlayingAlbumID == nil)
        .help(self.vm.isPodcast
            ? (self.vm.podcastID != nil ? L10n.string("Go to podcast show") : L10n.string("No album"))
            : (self.vm.nowPlayingAlbumID != nil ? L10n.string("Go to album: \(self.vm.album)") : L10n.string("No album")))
        .keyboardShortcut(KeyBindings.goToCurrentAlbum)
        .accessibilityLabel(
            self.vm.isPodcast
                ? (self.vm.podcastID != nil ? L10n.string("Go to podcast show") : L10n.string("No artwork"))
                : (self.vm.nowPlayingAlbumID != nil
                    ? L10n.string("Go to album \(self.vm.album) by \(self.vm.artist)")
                    : L10n.string("No artwork"))
        )
        .accessibilityIdentifier(A11y.NowPlaying.artworkButton)
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Title — click to jump to current track in the track list.
            Button {
                Task { await self.library.scrollToNowPlayingTrack() }
            } label: {
                Text(self.vm.title.isEmpty ? L10n.string("Not playing") : self.vm.title)
                    .font(Typography.body)
                    .foregroundStyle(self.vm.title.isEmpty ? Color.textSecondary : Color.textPrimary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(self.vm.nowPlayingTrackID == nil)
            .help(self.vm.nowPlayingTrackID != nil
                ? L10n.string("Jump to \"\(self.vm.title)\" in track list")
                : L10n.string("Not playing"))
            .keyboardShortcut(KeyBindings.jumpToCurrentTrack)
            .accessibilityLabel(
                self.vm.nowPlayingTrackID != nil
                    ? L10n.string("Jump to \(self.vm.title) in track list")
                    : L10n.string("Not playing")
            )
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier(A11y.NowPlaying.titleButton)

            // Artist/show — click to navigate to the artist or podcast show.
            if !self.vm.artist.isEmpty {
                Button {
                    if self.vm.isPodcast, let id = self.vm.podcastID {
                        Task { await self.library.selectDestination(.podcastShow(id)) }
                    } else {
                        Task { await self.library.goToCurrentArtist() }
                    }
                } label: {
                    Text(self.vm.isPodcast ? self.vm.artist : (self.trackSubtitle ?? self.vm.artist))
                        .font(Typography.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(self.vm.isPodcast ? self.vm.podcastID == nil : self.vm.nowPlayingArtistID == nil)
                .help(self.vm.isPodcast
                    ? (self.vm.podcastID != nil ? L10n.string("Go to podcast show") : self.vm.artist)
                    : (self.vm.nowPlayingArtistID != nil ? L10n.string("Go to artist: \(self.vm.artist)") : self.vm.artist))
                .keyboardShortcut(KeyBindings.goToCurrentArtist)
                .accessibilityLabel(self.vm.isPodcast
                    ? L10n.string("Go to podcast show")
                    : L10n.string("Go to artist \(self.vm.artist)"))
                .accessibilityIdentifier(A11y.NowPlaying.subtitleButton)
            }

            if let chapter = self.currentChapter {
                Text(verbatim: chapter.title)
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 120, maxWidth: 300, alignment: .leading)
        .onChange(of: self.vm.nowPlayingTrackID) { _, trackID in
            guard trackID != nil, !self.vm.title.isEmpty else { return }
            let msg = self.vm.artist.isEmpty
                ? self.vm.title
                : L10n.string("\(self.vm.title) by \(self.vm.artist)")
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: msg,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    }

    private var trackSubtitle: String? {
        let parts = [self.vm.artist, self.vm.album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }

    private var currentChapter: UIChapter? {
        guard self.vm.isPodcast else { return nil }
        return self.library.podcasts.nowPlayingChapters.current(at: self.vm.position)
    }

    @ViewBuilder
    private var transport: some View {
        if self.vm.isPodcast {
            PodcastTransportControls(
                vm: self.vm,
                loadTranscript: {
                    guard let podcastID = self.vm.podcastID, let guid = self.vm.podcastGUID else { return nil }
                    return await self.library.podcasts.loadTranscript(podcastID: podcastID, guid: guid)
                },
                chapters: self.library.podcasts.nowPlayingChapters,
                episode: self.library.podcasts.nowPlayingEpisode,
                showPersons: self.library.podcasts.nowPlayingShowPersons,
                podrollContext: PodrollContext(
                    items: self.library.podcasts.nowPlayingPodroll,
                    resolve: { await self.library.podcasts.resolvePodroll($0) },
                    onSelect: { self.library.openPodcastRecommendation($0) }
                )
            )
            // Key on podcastID *and* GUID: applyPodcastItem sets the GUID first and
            // resolves podcastID a beat later, so keying on the GUID alone can fire
            // while podcastID is still nil, bail, and never re-run -- leaving the
            // Show Notes button greyed even though chapters/notes are loadable.
            .task(id: "\(self.vm.podcastID ?? -1)|\(self.vm.podcastGUID ?? "")") {
                guard let podcastID = self.vm.podcastID, let guid = self.vm.podcastGUID else {
                    self.library.podcasts.clearNowPlayingChapters()
                    return
                }
                await self.library.podcasts.loadChapters(podcastID: podcastID, guid: guid)
                await self.library.podcasts.loadNowPlayingShowNotes(podcastID: podcastID, guid: guid)
            }
        } else {
            MusicTransportControls(vm: self.vm, library: self.library)
        }
    }

    private var panelButtons: some View {
        HStack(spacing: 14) {
            SpeedPickerView(vm: self.vm)

            SleepTimerMenu(vm: self.vm)

            if self.vm.pendingScrobbleCount > 0, self.scrobbleSettingsVM != nil {
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

    private var volumeAndScrubber: some View {
        VStack(spacing: 4) {
            self.scrubber
            self.volumeRow
        }
        .frame(maxWidth: 340)
    }

    private var scrubber: some View {
        HStack(spacing: 6) {
            Text(Formatters.duration(self.displayPosition))
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)

            Slider(
                value: Binding(
                    get: {
                        if let drag = self.scrubDragFraction { return drag }
                        return self.vm.duration > 0 ? self.vm.position / self.vm.duration : 0
                    },
                    set: { fraction in
                        // Hold the drag locally; seek once on release, not per move.
                        self.scrubDragFraction = fraction
                    }
                ),
                in: 0 ... 1
            ) { editing in
                if !editing, let fraction = self.scrubDragFraction {
                    let target = fraction * self.vm.duration
                    self.scrubDragFraction = nil
                    Task { await self.vm.scrub(to: target) }
                }
            }
            .controlSize(.mini)
            .disabled(self.vm.duration == 0)
            .id(self.accentColorKey)
            .help(L10n.string("Scrub to position"))
            .accessibilityLabel(L10n.string("Playback position"))
            .accessibilityValue(
                L10n.string("\(Formatters.duration(self.displayPosition)) of \(Formatters.duration(self.vm.duration))")
            )
            .accessibilityAdjustableAction { direction in
                guard direction == .increment || direction == .decrement else { return }
                let step = max(self.vm.duration * 0.05, 5)
                let pos = direction == .increment ? min(self.vm.position + step, self.vm.duration) : max(self.vm.position - step, 0)
                Task { await self.vm.scrub(to: pos) }
            }
            .accessibilityIdentifier(A11y.NowPlaying.scrubber)

            Text(Formatters.duration(self.vm.duration))
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .monospacedDigit()
                .frame(width: 36, alignment: .leading)
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 4) {
            Button {
                Task { await self.vm.toggleMute() }
            } label: {
                Image(systemName: self.vm.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(Typography.caption)
                    .foregroundStyle(self.vm.isMuted ? Color.primary : Color.textTertiary)
            }
            .buttonStyle(.plain)
            .help(self.vm.isMuted ? L10n.string("Unmute") : L10n.string("Mute"))
            .accessibilityLabel(self.vm.isMuted ? L10n.string("Unmute") : L10n.string("Mute"))
            .accessibilityIdentifier(A11y.NowPlaying.muteButton)
            .keyboardShortcut(KeyBindings.mute)

            Slider(value: Binding(
                get: { Double(self.vm.volume) },
                set: { newVolume in Task { await self.vm.setVolume(Float(newVolume)) } }
            ), in: 0 ... 1) { editing in
                if !editing { Haptics.positionCommit() }
            }
            .controlSize(.mini)
            .frame(maxWidth: 100)
            .id(self.accentColorKey)
            .help(L10n.string("Volume: \(Int(self.vm.volume * 100))%"))
            .accessibilityLabel(L10n.string("Volume"))
            .accessibilityValue(L10n.string("\(Int(self.vm.volume * 100)) percent"))
            .accessibilityAdjustableAction { direction in
                guard direction == .increment || direction == .decrement else { return }
                let vol = direction == .increment ? min(self.vm.volume + 0.1, 1) : max(self.vm.volume - 0.1, 0)
                Task { await self.vm.setVolume(vol) }
            }
            .accessibilityIdentifier(A11y.NowPlaying.volumeSlider)

            Image(systemName: "speaker.wave.3.fill")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Helpers

    /// Position shown under the scrubber — live engine position normally,
    /// but tracks the drag fraction while the user is scrubbing so the
    /// time readout mirrors where the thumb currently sits.
    private var displayPosition: TimeInterval {
        if let drag = self.scrubDragFraction {
            return drag * self.vm.duration
        }
        return self.vm.position
    }
}
