import AppKit
import SwiftUI

// MARK: - MiniPlayerCompact

/// Horizontal compact layout: thumbnail | title+artist | transport+scrubber.
/// Used when width ≥ 300 and height < 220.
struct MiniPlayerCompact: View {
    @ObservedObject var vm: MiniPlayerViewModel
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appearance.accentColor") private var accentColorKey = "system"
    @State private var dragPosition: Double?

    private var np: NowPlayingViewModel {
        self.vm.nowPlaying
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

    var body: some View {
        HStack(spacing: 10) {
            self.artworkThumbnail

            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(
                    self.np.title.isEmpty ? L10n.string("Not playing") : self.np.title,
                    font: .system(size: 12, weight: .semibold),
                    foregroundStyle: self.np.title.isEmpty ? Color.textSecondary : Color.textPrimary
                )

                if !self.np.artist.isEmpty {
                    MarqueeText(
                        self.np.artist,
                        font: .system(size: 11),
                        foregroundStyle: Color.textSecondary
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            self.transport

            self.scrubberStack
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Sub-views

    private var artworkThumbnail: some View {
        Group {
            if let img = self.np.artwork {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                GradientPlaceholder(seed: 1)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                self.openWindow(id: "track-info")
            } label: {
                Image(systemName: "info.circle")
                    .scaledSystemFont(size: 14, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.np.nowPlayingTrackID != nil ? Color.textPrimary : Color.textTertiary)
            .disabled(self.np.nowPlayingTrackID == nil)
            .help(L10n.string("Get info for current track"))
            .accessibilityLabel(L10n.string("Track Info"))

            Button {
                Task { await self.np.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .scaledSystemFont(size: 14, weight: .semibold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .help(L10n.string("Within first 3 seconds: previous track · After 3 seconds: restart current track"))
            .accessibilityLabel(L10n.string("Previous or restart"))

            Button {
                Task { await self.np.playPause() }
            } label: {
                Image(systemName: self.np.isPlaying ? "pause.fill" : "play.fill")
                    .scaledSystemFont(size: 18, weight: .bold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .help(self.np.isPlaying ? L10n.string("Pause") : L10n.string("Play"))
            .accessibilityLabel(self.np.isPlaying ? L10n.string("Pause") : L10n.string("Play"))

            Button {
                Task { await self.np.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .scaledSystemFont(size: 14, weight: .semibold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .help(L10n.string("Next track"))
            .accessibilityLabel(L10n.string("Next"))

            Button {
                Task { await self.np.toggleShuffle() }
            } label: {
                Image(systemName: "shuffle")
                    .scaledSystemFont(size: 12, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.np.shuffleOn ? AccentPalette.color(for: self.accentColorKey) : Color.textTertiary)
            .help(self.np.shuffleOn ? L10n.string("Shuffle: On — click to disable") : L10n.string("Shuffle: Off — click to enable"))
            .accessibilityLabel(self.np.shuffleOn ? L10n.string("Shuffle On") : L10n.string("Shuffle Off"))
            .accessibilityAddTraits(.isToggle)

            Button {
                Task { await self.np.cycleRepeat() }
            } label: {
                Image(systemName: self.np.repeatMode == .one ? "repeat.1" : "repeat")
                    .scaledSystemFont(size: 12, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.np.repeatMode == .off ? Color.textTertiary : AccentPalette.color(for: self.accentColorKey))
            .help(L10n.string("Repeat: \(self.repeatModeLabel) — click to cycle"))
            .accessibilityLabel(L10n.string("Repeat \(self.repeatModeLabel)"))
            .accessibilityAddTraits(.isToggle)

            Button {
                Task { await self.np.toggleStopAfterCurrent() }
            } label: {
                Image(systemName: "stop.circle\(self.np.stopAfterCurrent ? ".fill" : "")")
                    .scaledSystemFont(size: 12, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.np.stopAfterCurrent ? AccentPalette.color(for: self.accentColorKey) : Color.textTertiary)
            .help(self.np.stopAfterCurrent
                ? L10n.string("Stop after current track: On")
                : L10n.string("Stop after current track: Off"))
            .accessibilityLabel(self.np.stopAfterCurrent
                ? L10n.string("Stop After Current: On")
                : L10n.string("Stop After Current: Off"))
            .accessibilityAddTraits(.isToggle)
        }
    }

    private var scrubberStack: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { self.dragPosition ?? (self.np.duration > 0 ? self.np.position / self.np.duration : 0) },
                    set: { self.dragPosition = $0 }
                ),
                in: 0 ... 1
            ) { editing in
                if !editing, let fraction = self.dragPosition {
                    self.dragPosition = nil
                    Task { await self.np.scrub(to: fraction * self.np.duration) }
                }
            }
            .controlSize(.mini)
            .frame(width: 80)
            .id(self.accentColorKey)
            .disabled(self.np.duration == 0)
            .help(L10n.string("Scrub to position"))
            .accessibilityLabel(L10n.string("Playback position"))

            HStack {
                Text(Formatters.duration(self.dragPosition.map { $0 * self.np.duration } ?? self.np.position))
                Spacer()
                Text(Formatters.duration(self.np.duration))
            }
            .scaledSystemFont(size: 9)
            .foregroundStyle(Color.textTertiary)
            .frame(width: 80)
            .monospacedDigit()
        }
    }
}
