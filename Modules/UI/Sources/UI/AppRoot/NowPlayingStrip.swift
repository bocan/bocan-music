import SwiftUI

// MARK: - NowPlayingStrip

/// The 72pt-tall transport bar anchored at the bottom of every main view.
///
/// Shows current track artwork, title/artist/album, play/pause and scrubber,
/// and a volume slider.  Prev/Next buttons are present but disabled until
/// Phase 5 introduces the queue.
public struct NowPlayingStrip: View {
    public var vm: NowPlayingViewModel
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(DSPViewModel.self) private var dsp: DSPViewModel
    @EnvironmentObject private var visualizer: VisualizerViewModel
    /// Optional — only the main window injects a `RouteViewModel`. Snapshot
    /// tests and other ad-hoc surfaces can skip it.
    @ObservedObject private var route: RouteViewModel

    /// While the user is actively dragging the scrubber, we hold the drag
    /// fraction locally so the Slider doesn't fight the live `vm.position`
    /// updates coming from the engine.  Seeking happens once on release.
    @AppStorage("appearance.accentColor") private var accentColorKey = "system"
    @State private var scrubDragFraction: Double?
    @State private var showDSP = false

    public init(vm: NowPlayingViewModel, route: RouteViewModel? = nil) {
        self.vm = vm
        self.route = route ?? RouteViewModel.placeholder
    }

    public var body: some View {
        HStack(spacing: 12) {
            self.artwork
            self.trackInfo
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
        .frame(height: Theme.nowPlayingStripHeight)
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.NowPlaying.strip)
        .sheet(isPresented: self.$showDSP) {
            DSPSheet(vm: self.dsp)
        }
        // Allow DSPViewModel.showDSPPanel to open the sheet from menu commands
        // and keyboard shortcuts that don't have direct access to @State.
        .onChange(of: self.dsp.showDSPPanel) { _, requested in
            if requested {
                self.showDSP = true
                self.dsp.showDSPPanel = false
            }
        }
    }

    // MARK: - Sub-views

    private var artwork: some View {
        Group {
            if let img = vm.artwork {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.artworkCornerRadius, style: .continuous))
                    .accessibilityLabel("\(self.vm.album) by \(self.vm.artist)")
            } else {
                GradientPlaceholder(seed: 0)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.artworkCornerRadius, style: .continuous))
                    .accessibilityLabel("No artwork")
            }
        }
        .accessibilityIdentifier(A11y.NowPlaying.artwork)
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.vm.title.isEmpty ? "Not playing" : self.vm.title)
                .font(Typography.body)
                .foregroundStyle(self.vm.title.isEmpty ? Color.textSecondary : Color.textPrimary)
                .lineLimit(1)
                .accessibilityIdentifier(A11y.NowPlaying.title)

            if let subtitle = self.trackSubtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(Typography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .accessibilityIdentifier(A11y.NowPlaying.artist)
            }
        }
        .frame(minWidth: 120, maxWidth: 300, alignment: .leading)
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
                self.library.showTagEditorForNowPlaying()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.nowPlayingTrackID != nil ? Color.textPrimary : Color.textTertiary)
            .disabled(self.vm.nowPlayingTrackID == nil)
            .help("Get info for current track")
            .accessibilityLabel("Track Info")

            Button {
                Task { await self.vm.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .help("Previous track (or restart current)")
            .accessibilityLabel("Previous")
            .accessibilityIdentifier(A11y.NowPlaying.prevButton)

            Button {
                Task { await self.vm.playPause() }
            } label: {
                Image(systemName: self.vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .keyboardShortcut(KeyBindings.playPause)
            .help(self.vm.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(self.vm.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier(A11y.NowPlaying.playPauseButton)

            Button {
                Task { await self.vm.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .help("Next track")
            .accessibilityLabel("Next")
            .accessibilityIdentifier(A11y.NowPlaying.nextButton)

            Button {
                Task { await self.vm.toggleShuffle() }
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.shuffleOn ? AccentPalette.color(for: self.accentColorKey) : Color.textTertiary)
            .help(self.vm.shuffleOn ? "Shuffle: On — click to disable" : "Shuffle: Off — click to enable")
            .accessibilityLabel(self.vm.shuffleOn ? "Shuffle On" : "Shuffle Off")
            .accessibilityHint(self.vm.shuffleOn ? "Activate to turn shuffle off" : "Activate to turn shuffle on")
            .accessibilityAddTraits(.isToggle)

            Button {
                Task { await self.vm.cycleRepeat() }
            } label: {
                Image(systemName: self.vm.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.repeatMode == .off ? Color.textTertiary : AccentPalette.color(for: self.accentColorKey))
            .help("Repeat: \(self.vm.repeatMode == .off ? "Off" : self.vm.repeatMode == .all ? "All" : "One") — click to cycle")
            .accessibilityLabel("Repeat \(self.vm.repeatMode == .off ? "Off" : self.vm.repeatMode == .all ? "All" : "One")")
            .accessibilityHint({
                switch self.vm.repeatMode {
                case .off:
                    "Activate to repeat all tracks"

                case .all:
                    "Activate to repeat current track"

                case .one:
                    "Activate to turn repeat off"
                }
            }())
            .accessibilityAddTraits(.isToggle)

            Button {
                Task { await self.vm.toggleStopAfterCurrent() }
            } label: {
                Image(systemName: "stop.circle\(self.vm.stopAfterCurrent ? ".fill" : "")")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.stopAfterCurrent ? AccentPalette.color(for: self.accentColorKey) : Color.textTertiary)
            .help(self.vm.stopAfterCurrent ? "Stop after current track: On" : "Stop after current track: Off")
            .accessibilityLabel(self.vm.stopAfterCurrent ? "Stop After Current: On" : "Stop After Current: Off")
            .accessibilityHint(self.vm
                .stopAfterCurrent ? "Activate to keep playing after this track" : "Activate to stop playback after this track")
            .accessibilityAddTraits(.isToggle)
        }
    }

    private var panelButtons: some View {
        HStack(spacing: 14) {
            SpeedPickerView(vm: self.vm)

            SleepTimerMenu(vm: self.vm)

            Button {
                self.showDSP.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(KeyBindings.showEQPanel)
            .foregroundStyle(self.showDSP ? Color.accentColor : Color.textPrimary)
            .help("Equaliser & DSP (⌘⌥E)")
            .accessibilityLabel("Equaliser & DSP")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.visualizer.paneVisible.toggle()
                }
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.visualizer.paneVisible ? Color.accentColor : Color.textPrimary)
            .help(self.visualizer.paneVisible ? "Hide Visualizer" : "Show Visualizer")
            .accessibilityLabel(self.visualizer.paneVisible ? "Hide Visualizer" : "Show Visualizer")
            .accessibilityAddTraits(.isToggle)
            .accessibilityIdentifier(A11y.Visualizer.host)
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
            Image(systemName: "speaker.fill")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
                .accessibilityHidden(true)

            Slider(value: Binding(
                get: { Double(self.vm.volume) },
                set: { newVolume in Task { await self.vm.setVolume(Float(newVolume)) } }
            ), in: 0 ... 1)
                .controlSize(.mini)
                .frame(maxWidth: 100)
                .id(self.accentColorKey)
                .help("Volume: \(Int(self.vm.volume * 100))%")
                .accessibilityLabel("Volume")
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
