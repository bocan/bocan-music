import AppKit
import SwiftUI

// MARK: - MiniPlayerCompact

/// Horizontal compact layout: thumbnail | title+artist | transport+scrubber.
/// Used when width ≥ 300 and height < 220.
struct MiniPlayerCompact: View {
    @ObservedObject var vm: MiniPlayerViewModel
    @EnvironmentObject private var library: LibraryViewModel
    @AppStorage("appearance.accentColor") private var accentColorKey = "system"
    @State private var dragPosition: Double?

    private var np: NowPlayingViewModel {
        self.vm.nowPlaying
    }

    var body: some View {
        HStack(spacing: 10) {
            self.artworkThumbnail

            VStack(alignment: .leading, spacing: 2) {
                Text(self.np.title.isEmpty ? "Not playing" : self.np.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(self.np.title.isEmpty ? Color.textSecondary : Color.textPrimary)

                if !self.np.artist.isEmpty {
                    Text(self.np.artist)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(Color.textSecondary)
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
                self.library.showTagEditorForNowPlaying()
                if let win = MainWindowTracker.shared.window {
                    win.makeKeyAndOrderFront(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.np.nowPlayingTrackID != nil ? Color.textPrimary : Color.textTertiary)
            .disabled(self.np.nowPlayingTrackID == nil)
            .help("Get info for current track")
            .accessibilityLabel("Track Info")

            Button {
                Task { await self.np.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .help("Previous track")
            .accessibilityLabel("Previous")

            Button {
                Task { await self.np.playPause() }
            } label: {
                Image(systemName: self.np.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .help(self.np.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(self.np.isPlaying ? "Pause" : "Play")

            Button {
                Task { await self.np.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .help("Next track")
            .accessibilityLabel("Next")

            Button {
                Task { await self.np.toggleShuffle() }
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.np.shuffleOn ? AccentPalette.color(for: self.accentColorKey) : Color.textTertiary)
            .help(self.np.shuffleOn ? "Shuffle: On — click to disable" : "Shuffle: Off — click to enable")
            .accessibilityLabel(self.np.shuffleOn ? "Shuffle On" : "Shuffle Off")
            .accessibilityAddTraits(.isToggle)

            Button {
                Task { await self.np.cycleRepeat() }
            } label: {
                Image(systemName: self.np.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.np.repeatMode == .off ? Color.textTertiary : AccentPalette.color(for: self.accentColorKey))
            .help("Repeat: \(self.np.repeatMode == .off ? "Off" : self.np.repeatMode == .all ? "All" : "One") — click to cycle")
            .accessibilityLabel("Repeat \(self.np.repeatMode == .off ? "Off" : self.np.repeatMode == .all ? "All" : "One")")
            .accessibilityAddTraits(.isToggle)

            Button {
                Task { await self.np.toggleStopAfterCurrent() }
            } label: {
                Image(systemName: "stop.circle\(self.np.stopAfterCurrent ? ".fill" : "")")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.np.stopAfterCurrent ? AccentPalette.color(for: self.accentColorKey) : Color.textTertiary)
            .help(self.np.stopAfterCurrent ? "Stop after current track: On" : "Stop after current track: Off")
            .accessibilityLabel(self.np.stopAfterCurrent ? "Stop After Current: On" : "Stop After Current: Off")
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
            .help("Scrub to position")
            .accessibilityLabel("Playback position")

            HStack {
                Text(Formatters.duration(self.dragPosition.map { $0 * self.np.duration } ?? self.np.position))
                Spacer()
                Text(Formatters.duration(self.np.duration))
            }
            .font(.system(size: 9))
            .foregroundStyle(Color.textTertiary)
            .frame(width: 80)
            .monospacedDigit()
        }
    }
}
