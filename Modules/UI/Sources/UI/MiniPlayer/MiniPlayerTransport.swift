import SwiftUI

// MARK: - MiniPlayerTransport

/// The shared transport-button row for every Mini Player layout, podcast-aware.
///
/// For a podcast episode it shows skip-back / play-pause / skip-forward (matching
/// `PodcastTransportControls` in the main strip): the track-oriented controls
/// (previous/next track, shuffle, repeat, stop-after-current, track info) are
/// meaningless for an episode and skip-back/forward seek within it. For music it
/// shows the full set (`.full`) or the strip's reduced set (`.strip`).
///
/// Sizes and the colour palette are parameterised so each layout keeps its existing
/// look (the visualizer tints its controls white over the Metal background).
struct MiniPlayerTransport: View {
    enum MusicLayout {
        /// Compact / square / visualizer: info, prev, play, next, shuffle, repeat, stop.
        case full
        /// Strip: play, shuffle, repeat, stop (no track navigation or info).
        case strip
    }

    /// Foreground colours per layout. Active toggles always use the accent colour.
    struct Palette {
        var primary: Color
        var infoEnabled: Color
        var infoDisabled: Color
        var inactiveAccent: Color

        /// On `adaptiveMaterial` (compact, square, strip).
        static let standard = Self(
            primary: .textPrimary,
            infoEnabled: .textPrimary,
            infoDisabled: .textTertiary,
            inactiveAccent: .textTertiary
        )

        /// Over the Metal visualizer, where white reads against any frame.
        static let onVisualizer = Self(
            primary: .white,
            infoEnabled: .white.opacity(0.85),
            infoDisabled: .white.opacity(0.35),
            inactiveAccent: .white.opacity(0.6)
        )
    }

    var np: NowPlayingViewModel
    var musicLayout: MusicLayout = .full
    var palette: Palette = .standard
    /// Opens the Track Info window (music `.full` only).
    var openInfoWindow: () -> Void = {}
    var spacing: CGFloat
    /// prev / next / skip / info glyphs.
    var secondarySize: CGFloat
    /// play / pause glyph.
    var primarySize: CGFloat
    /// shuffle / repeat / stop-after glyphs (music only).
    var accentSize: CGFloat

    @AppStorage("appearance.accentColor") private var accentColorKey = "system"

    private var activeAccent: Color {
        AccentPalette.color(for: self.accentColorKey)
    }

    var body: some View {
        HStack(spacing: self.spacing) {
            if self.np.isPodcast {
                self.skipBackButton
                self.playPauseButton
                self.skipForwardButton
            } else {
                if self.musicLayout == .full {
                    self.infoButton
                    self.previousButton
                }
                self.playPauseButton
                if self.musicLayout == .full {
                    self.nextButton
                }
                self.shuffleButton
                self.repeatButton
                self.stopAfterButton
            }
        }
    }

    // MARK: - Shared

    private var playPauseButton: some View {
        Button {
            Task { await self.np.playPause() }
        } label: {
            Image(systemName: self.np.isPlaying ? "pause.fill" : "play.fill")
                .scaledSystemFont(size: self.primarySize, weight: .bold)
        }
        .buttonStyle(.plain)
        .foregroundStyle(self.palette.primary)
        .help(self.np.isPlaying ? L10n.string("Pause") : L10n.string("Play"))
        .accessibilityLabel(self.np.isPlaying ? L10n.string("Pause") : L10n.string("Play"))
    }

    // MARK: - Podcast

    private var skipBackButton: some View {
        Button {
            Task { await self.np.skipBack() }
        } label: {
            Image(systemName: "gobackward.15")
                .scaledSystemFont(size: self.secondarySize, weight: .semibold)
        }
        .buttonStyle(.plain)
        .foregroundStyle(self.palette.primary)
        .help(L10n.string("Skip back 15 seconds"))
        .accessibilityLabel(L10n.string("Skip back 15 seconds"))
    }

    private var skipForwardButton: some View {
        Button {
            Task { await self.np.skipForward() }
        } label: {
            Image(systemName: "goforward.30")
                .scaledSystemFont(size: self.secondarySize, weight: .semibold)
        }
        .buttonStyle(.plain)
        .foregroundStyle(self.palette.primary)
        .help(L10n.string("Skip forward 30 seconds"))
        .accessibilityLabel(L10n.string("Skip forward 30 seconds"))
    }

    // MARK: - Music

    private var infoButton: some View {
        Button {
            self.openInfoWindow()
        } label: {
            Image(systemName: "info.circle")
                .scaledSystemFont(size: self.secondarySize, weight: .medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(self.np.nowPlayingTrackID != nil ? self.palette.infoEnabled : self.palette.infoDisabled)
        .disabled(self.np.nowPlayingTrackID == nil)
        .help(L10n.string("Get info for current track"))
        .accessibilityLabel(L10n.string("Track Info"))
    }

    private var previousButton: some View {
        Button {
            Task { await self.np.previous() }
        } label: {
            Image(systemName: "backward.fill")
                .scaledSystemFont(size: self.secondarySize, weight: .semibold)
        }
        .buttonStyle(.plain)
        .foregroundStyle(self.palette.primary)
        .help(L10n.string("Within first 3 seconds: previous track · After 3 seconds: restart current track"))
        .accessibilityLabel(L10n.string("Previous or restart"))
    }

    private var nextButton: some View {
        Button {
            Task { await self.np.next() }
        } label: {
            Image(systemName: "forward.fill")
                .scaledSystemFont(size: self.secondarySize, weight: .semibold)
        }
        .buttonStyle(.plain)
        .foregroundStyle(self.palette.primary)
        .help(L10n.string("Next track"))
        .accessibilityLabel(L10n.string("Next"))
    }

    private var shuffleButton: some View {
        Button {
            Task { await self.np.toggleShuffle() }
        } label: {
            Image(systemName: "shuffle")
                .scaledSystemFont(size: self.accentSize, weight: .medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(self.np.shuffleOn ? self.activeAccent : self.palette.inactiveAccent)
        .help(self.np.shuffleOn
            ? L10n.string("Shuffle: On — click to disable")
            : L10n.string("Shuffle: Off — click to enable"))
        .accessibilityLabel(self.np.shuffleOn ? L10n.string("Shuffle On") : L10n.string("Shuffle Off"))
        .accessibilityAddTraits(.isToggle)
    }

    private var repeatButton: some View {
        Button {
            Task { await self.np.cycleRepeat() }
        } label: {
            Image(systemName: self.np.repeatMode == .one ? "repeat.1" : "repeat")
                .scaledSystemFont(size: self.accentSize, weight: .medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(self.np.repeatMode == .off ? self.palette.inactiveAccent : self.activeAccent)
        .help(L10n.string("Repeat: \(self.repeatModeLabel) — click to cycle"))
        .accessibilityLabel(L10n.string("Repeat \(self.repeatModeLabel)"))
        .accessibilityAddTraits(.isToggle)
    }

    private var stopAfterButton: some View {
        Button {
            Task { await self.np.toggleStopAfterCurrent() }
        } label: {
            Image(systemName: "stop.circle\(self.np.stopAfterCurrent ? ".fill" : "")")
                .scaledSystemFont(size: self.accentSize, weight: .medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(self.np.stopAfterCurrent ? self.activeAccent : self.palette.inactiveAccent)
        .help(self.np.stopAfterCurrent
            ? L10n.string("Stop after current track: On")
            : L10n.string("Stop after current track: Off"))
        .accessibilityLabel(self.np.stopAfterCurrent
            ? L10n.string("Stop After Current: On")
            : L10n.string("Stop After Current: Off"))
        .accessibilityAddTraits(.isToggle)
    }

    /// Localized label for the current repeat mode ("Off" / "All" / "One").
    private var repeatModeLabel: String {
        switch self.np.repeatMode {
        case .off:
            L10n.string("Off")

        case .all:
            L10n.string("All")

        case .one:
            L10n.string("One")
        }
    }
}
