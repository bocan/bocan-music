import SwiftUI

// MARK: - MusicTransportControls

/// The transport control row shown in `NowPlayingStrip` when playing music
/// (not a podcast). Contains love, info, previous, play/pause, next, shuffle,
/// repeat, and stop-after-current buttons.
struct MusicTransportControls: View {
    var vm: NowPlayingViewModel
    var library: LibraryViewModel
    @AppStorage("appearance.accentColor") private var accentColorKey = "system"

    var body: some View {
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
                    ? Color.lovedTint
                    : (self.vm.nowPlayingTrackID != nil ? Color.textPrimary : Color.textTertiary)
            )
            .disabled(self.vm.nowPlayingTrackID == nil)
            .help(self.vm.nowPlayingIsLoved ? L10n.string("Unlove current track (⌘L)") : L10n.string("Love current track (⌘L)"))
            .accessibilityLabel(self.vm.nowPlayingIsLoved ? L10n.string("Loved") : L10n.string("Not Loved"))
            .accessibilityHint(self.vm.nowPlayingIsLoved ? L10n.string("Activate to unlove") : L10n.string("Activate to love"))
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
            .help(L10n.string("Get info for current track"))
            .accessibilityLabel(L10n.string("Track Info"))
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
            .help(L10n.string("Within first 3 seconds: previous track · After 3 seconds: restart current track"))
            .accessibilityLabel(L10n.string("Previous or restart"))
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
            .help(self.vm.isPlaying ? L10n.string("Pause") : L10n.string("Play"))
            .accessibilityLabel(self.vm.isPlaying ? L10n.string("Pause") : L10n.string("Play"))
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
            .help(L10n.string("Next track"))
            .accessibilityLabel(L10n.string("Next track"))
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
            .help(self.vm.shuffleOn ? L10n.string("Shuffle: On — click to disable") : L10n.string("Shuffle: Off — click to enable"))
            .accessibilityLabel(L10n.string("Shuffle"))
            .accessibilityValue(self.vm.shuffleOn ? L10n.string("on") : L10n.string("off"))
            .accessibilityHint(self.vm.shuffleOn ? L10n.string("Activate to turn shuffle off") : L10n.string("Activate to turn shuffle on"))
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
            .help(L10n.string("Repeat: \(self.repeatModeLabel) — click to cycle"))
            .accessibilityLabel(L10n.string("Repeat"))
            .accessibilityValue(self.vm.repeatMode == .off ? L10n.string("off")
                : self.vm.repeatMode == .all ? L10n.string("all") : L10n.string("one"))
            .accessibilityHint(self.vm.repeatMode == .off ? L10n.string("Activate to repeat all tracks")
                : self.vm.repeatMode == .all ? L10n.string("Activate to repeat current track")
                : L10n.string("Activate to turn repeat off"))
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
            .help(self.vm.stopAfterCurrent ? L10n.string("Stop after current track: On") : L10n.string("Stop after current track: Off"))
            .accessibilityLabel(self.vm.stopAfterCurrent
                ? L10n.string("Stop After Current: On") : L10n.string("Stop After Current: Off"))
            .accessibilityHint(self.vm.stopAfterCurrent
                ? L10n.string("Activate to keep playing after this track")
                : L10n.string("Activate to stop playback after this track"))
            .accessibilityAddTraits(.isToggle)
            .accessibilityIdentifier(A11y.NowPlaying.stopAfterCurrentButton)
        }
        .focusSection()
    }

    private var repeatModeLabel: String {
        self.vm.repeatMode == .off ? L10n.string("Off")
            : self.vm.repeatMode == .all ? L10n.string("All") : L10n.string("One")
    }
}
