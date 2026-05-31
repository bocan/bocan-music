// swiftlint:disable type_body_length
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
    /// Optional — only the main window injects a `RouteViewModel`. Snapshot
    /// tests and other ad-hoc surfaces can skip it.
    private var route: RouteViewModel

    /// While the user is actively dragging the scrubber, we hold the drag
    /// fraction locally so the Slider doesn't fight the live `vm.position`
    /// updates coming from the engine.  Seeking happens once on release.
    @AppStorage("appearance.accentColor") private var accentColorKey = "system"
    @State private var scrubDragFraction: Double?
    @AppStorage("scrobble.showRecentSheet") private var showRecentScrobbles = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Optional — only the main window injects a `ScrobbleSettingsViewModel`.
    /// When non-nil and `vm.pendingScrobbleCount > 0`, a pending-scrobbles
    /// indicator is shown in the panel-buttons area.
    var scrobbleSettingsVM: ScrobbleSettingsViewModel?

    public init(vm: NowPlayingViewModel, route: RouteViewModel? = nil, scrobbleSettingsVM: ScrobbleSettingsViewModel? = nil) {
        self.vm = vm
        self.route = route ?? RouteViewModel.placeholder
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
            Divider()
                .frame(height: 32)
                .padding(.horizontal, 4)
            RoutePicker(vm: self.route)
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
            Task { await self.library.goToCurrentAlbum() }
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
        .disabled(self.vm.nowPlayingAlbumID == nil)
        .help(self.vm.nowPlayingAlbumID != nil ? "Go to album: \(self.vm.album)" : "No album")
        .keyboardShortcut(KeyBindings.goToCurrentAlbum)
        .accessibilityLabel(
            self.vm.nowPlayingAlbumID != nil
                ? "Go to album \(self.vm.album) by \(self.vm.artist)"
                : "No artwork"
        )
        .accessibilityIdentifier(A11y.NowPlaying.artworkButton)
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Title — click to jump to current track in the track list.
            Button {
                Task { await self.library.scrollToNowPlayingTrack() }
            } label: {
                Text(self.vm.title.isEmpty ? "Not playing" : self.vm.title)
                    .font(Typography.body)
                    .foregroundStyle(self.vm.title.isEmpty ? Color.textSecondary : Color.textPrimary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(self.vm.nowPlayingTrackID == nil)
            .help(self.vm.nowPlayingTrackID != nil ? "Jump to \"\(self.vm.title)\" in track list" : "Not playing")
            .keyboardShortcut(KeyBindings.jumpToCurrentTrack)
            .accessibilityLabel(
                self.vm.nowPlayingTrackID != nil
                    ? "Jump to \(self.vm.title) in track list"
                    : "Not playing"
            )
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier(A11y.NowPlaying.titleButton)

            // Artist — click to navigate to the artist view.
            if !self.vm.artist.isEmpty {
                Button {
                    Task { await self.library.goToCurrentArtist() }
                } label: {
                    Text(self.trackSubtitle ?? self.vm.artist)
                        .font(Typography.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(self.vm.nowPlayingArtistID == nil)
                .help(self.vm.nowPlayingArtistID != nil ? "Go to artist: \(self.vm.artist)" : self.vm.artist)
                .keyboardShortcut(KeyBindings.goToCurrentArtist)
                .accessibilityLabel("Go to artist \(self.vm.artist)")
                .accessibilityIdentifier(A11y.NowPlaying.subtitleButton)
            }
        }
        .frame(minWidth: 120, maxWidth: 300, alignment: .leading)
        .onChange(of: self.vm.nowPlayingTrackID) { _, trackID in
            guard trackID != nil, !self.vm.title.isEmpty else { return }
            let msg = self.vm.artist.isEmpty
                ? self.vm.title
                : "\(self.vm.title) by \(self.vm.artist)"
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

    private var transport: some View {
        HStack(spacing: 20) {
            Button {
                self.library.toggleLovedForNowPlaying()
            } label: {
                Image(systemName: self.vm.nowPlayingIsLoved ? "heart.fill" : "heart")
                    .scaledSystemFont(size: 15, weight: .medium)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                self.vm.nowPlayingIsLoved
                    ? Color(red: 1.0, green: 0.176, blue: 0.333)
                    : (self.vm.nowPlayingTrackID != nil ? Color.textPrimary : Color.textTertiary)
            )
            .disabled(self.vm.nowPlayingTrackID == nil)
            .help(self.vm.nowPlayingIsLoved ? "Unlove current track (⌘L)" : "Love current track (⌘L)")
            .accessibilityLabel(self.vm.nowPlayingIsLoved ? "Loved" : "Not Loved")
            .accessibilityHint(self.vm.nowPlayingIsLoved ? "Activate to unlove" : "Activate to love")
            .accessibilityAddTraits(.isToggle)
            .accessibilityIdentifier(A11y.NowPlaying.loveButton)

            Button {
                self.library.showTagEditorForNowPlaying()
            } label: {
                Image(systemName: "info.circle")
                    .scaledSystemFont(size: 15, weight: .medium)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.nowPlayingTrackID != nil ? Color.textPrimary : Color.textTertiary)
            .disabled(self.vm.nowPlayingTrackID == nil)
            .help("Get info for current track")
            .accessibilityLabel("Track Info")
            .accessibilityIdentifier(A11y.NowPlaying.infoButton)

            Button {
                Task { await self.vm.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .scaledSystemFont(size: 18, weight: .semibold)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.title.isEmpty ? Color.textTertiary : Color.textPrimary)
            .disabled(self.vm.title.isEmpty)
            .help("Within first 3 seconds: previous track · After 3 seconds: restart current track")
            .accessibilityLabel("Previous or restart")
            .accessibilityIdentifier(A11y.NowPlaying.prev)

            Button {
                Task { await self.vm.playPause() }
            } label: {
                Image(systemName: self.vm.isPlaying ? "pause.fill" : "play.fill")
                    .scaledSystemFont(size: 24, weight: .bold)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .keyboardShortcut(KeyBindings.playPause)
            .help(self.vm.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(self.vm.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier(A11y.NowPlaying.playPause)

            Button {
                Task { await self.vm.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .scaledSystemFont(size: 18, weight: .semibold)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.title.isEmpty ? Color.textTertiary : Color.textPrimary)
            .disabled(self.vm.title.isEmpty)
            .help("Next track")
            .accessibilityLabel("Next track")
            .accessibilityIdentifier(A11y.NowPlaying.next)

            Button {
                Task { await self.vm.toggleShuffle() }
            } label: {
                Image(systemName: "shuffle")
                    .scaledSystemFont(size: 15, weight: .medium)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.shuffleOn ? AccentPalette.color(for: self.accentColorKey) : Color.textTertiary)
            .activeToggleIndicator(self.vm.shuffleOn)
            .help(self.vm.shuffleOn ? "Shuffle: On — click to disable" : "Shuffle: Off — click to enable")
            .accessibilityLabel("Shuffle")
            .accessibilityValue(self.vm.shuffleOn ? "on" : "off")
            .accessibilityHint(self.vm.shuffleOn ? "Activate to turn shuffle off" : "Activate to turn shuffle on")
            .accessibilityAddTraits(.isToggle)
            .accessibilityIdentifier(A11y.NowPlaying.shuffleButton)

            Button {
                Task { await self.vm.cycleRepeat() }
            } label: {
                Image(systemName: self.vm.repeatMode == .one ? "repeat.1" : "repeat")
                    .scaledSystemFont(size: 15, weight: .medium)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.repeatMode == .off ? Color.textTertiary : AccentPalette.color(for: self.accentColorKey))
            .activeToggleIndicator(self.vm.repeatMode != .off)
            .help("Repeat: \(self.vm.repeatMode == .off ? "Off" : self.vm.repeatMode == .all ? "All" : "One") — click to cycle")
            .accessibilityLabel("Repeat")
            .accessibilityValue(self.vm.repeatMode == .off ? "off" : self.vm.repeatMode == .all ? "all" : "one")
            .accessibilityHint(self.vm.repeatMode == .off ? "Activate to repeat all tracks"
                : self.vm.repeatMode == .all ? "Activate to repeat current track"
                : "Activate to turn repeat off")
            .accessibilityAddTraits(.isToggle)
            .accessibilityIdentifier(A11y.NowPlaying.repeatButton)

            Button {
                Task { await self.vm.toggleStopAfterCurrent() }
            } label: {
                Image(systemName: "stop.circle\(self.vm.stopAfterCurrent ? ".fill" : "")")
                    .scaledSystemFont(size: 15, weight: .medium)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.stopAfterCurrent ? AccentPalette.color(for: self.accentColorKey) : Color.textTertiary)
            .activeToggleIndicator(self.vm.stopAfterCurrent)
            .help(self.vm.stopAfterCurrent ? "Stop after current track: On" : "Stop after current track: Off")
            .accessibilityLabel(self.vm.stopAfterCurrent ? "Stop After Current: On" : "Stop After Current: Off")
            .accessibilityHint(self.vm
                .stopAfterCurrent ? "Activate to keep playing after this track" : "Activate to stop playback after this track")
            .accessibilityAddTraits(.isToggle)
            .accessibilityIdentifier(A11y.NowPlaying.stopAfterCurrentButton)
        }
        .focusSection()
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
                .foregroundStyle(Color.orange)
                .help("Scrobbles pending: \(self.vm.pendingScrobbleCount) — click to view")
                .accessibilityLabel("Scrobbles pending")
                .accessibilityValue("\(self.vm.pendingScrobbleCount)")
                .accessibilityHint("Click to view recent scrobbles")
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
            .help("Equaliser & DSP (⌘⌥E)")
            .accessibilityLabel(
                self.dsp.isEQActive || self.dsp.hasScopedPreset
                    ? "Equaliser & DSP — active" : "Equaliser & DSP"
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
                        // Update only the local drag value while the user is
                        // dragging; don't spawn a seek task per mouse move.
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
            .help("Scrub to position")
            .accessibilityLabel("Playback position")
            .accessibilityValue(Formatters.duration(self.displayPosition) + " of " + Formatters.duration(self.vm.duration))
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
            .help(self.vm.isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(self.vm.isMuted ? "Unmute" : "Mute")
            .accessibilityIdentifier(A11y.NowPlaying.muteButton)
            .keyboardShortcut(KeyBindings.mute)

            Slider(value: Binding(
                get: { Double(self.vm.volume) },
                set: { newVolume in Task { await self.vm.setVolume(Float(newVolume)) } }
            ), in: 0 ... 1)
                .controlSize(.mini)
                .frame(maxWidth: 100)
                .id(self.accentColorKey)
                .help("Volume: \(Int(self.vm.volume * 100))%")
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int(self.vm.volume * 100)) percent")
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

// swiftlint:enable type_body_length
