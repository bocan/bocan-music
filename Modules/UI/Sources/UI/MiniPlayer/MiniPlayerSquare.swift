import AppKit
import SwiftUI

// MARK: - MiniPlayerSquare

/// Square artwork-first layout: used when width ≥ 220 and height ≥ 220.
struct MiniPlayerSquare: View {
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

    private var trackSubtitle: String? {
        let parts = [self.np.artist, self.np.album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " – ")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-bleed artwork background
            self.artworkBackground

            // Overlay gradient + controls
            VStack(spacing: 0) {
                Spacer()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)
                .overlay(alignment: .bottom) {
                    self.controls
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Sub-views

    private var artworkBackground: some View {
        Group {
            if let img = self.np.artwork {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                GradientPlaceholder(seed: 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    private var controls: some View {
        VStack(spacing: 6) {
            // Title + artist – album (white text on dark gradient)
            VStack(spacing: 2) {
                MarqueeText(
                    self.np.title.isEmpty ? L10n.string("Not playing") : self.np.title,
                    font: .system(size: 13, weight: .semibold),
                    foregroundStyle: Color.white
                )

                if let subtitle = self.trackSubtitle {
                    MarqueeText(
                        subtitle,
                        font: .system(size: 11),
                        foregroundStyle: Color.white.opacity(0.8)
                    )
                }
            }

            // Thin scrubber
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
            .tint(.white)
            .disabled(self.np.duration == 0)
            .help(L10n.string("Scrub to position"))
            .accessibilityLabel(L10n.string("Playback position"))

            // Transport
            HStack(spacing: 16) {
                Button {
                    self.openWindow(id: "track-info")
                } label: {
                    Image(systemName: "info.circle")
                        .scaledSystemFont(size: 13, weight: .medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.np.nowPlayingTrackID != nil ? .white.opacity(0.85) : .white.opacity(0.35))
                .disabled(self.np.nowPlayingTrackID == nil)
                .help(L10n.string("Get info for current track"))
                .accessibilityLabel(L10n.string("Track Info"))

                Button {
                    Task { await self.np.previous() }
                } label: {
                    Image(systemName: "backward.fill")
                        .scaledSystemFont(size: 16, weight: .semibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help(L10n.string("Within first 3 seconds: previous track · After 3 seconds: restart current track"))
                .accessibilityLabel(L10n.string("Previous or restart"))

                Button {
                    Task { await self.np.playPause() }
                } label: {
                    Image(systemName: self.np.isPlaying ? "pause.fill" : "play.fill")
                        .scaledSystemFont(size: 22, weight: .bold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help(self.np.isPlaying ? L10n.string("Pause") : L10n.string("Play"))
                .accessibilityLabel(self.np.isPlaying ? L10n.string("Pause") : L10n.string("Play"))

                Button {
                    Task { await self.np.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .scaledSystemFont(size: 16, weight: .semibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help(L10n.string("Next track"))
                .accessibilityLabel(L10n.string("Next"))

                Button {
                    Task { await self.np.toggleShuffle() }
                } label: {
                    Image(systemName: "shuffle")
                        .scaledSystemFont(size: 13, weight: .medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.np.shuffleOn ? AccentPalette.color(for: self.accentColorKey) : .white.opacity(0.6))
                .help(self.np.shuffleOn ? L10n.string("Shuffle: On — click to disable") : L10n.string("Shuffle: Off — click to enable"))
                .accessibilityLabel(self.np.shuffleOn ? L10n.string("Shuffle On") : L10n.string("Shuffle Off"))
                .accessibilityAddTraits(.isToggle)

                Button {
                    Task { await self.np.cycleRepeat() }
                } label: {
                    Image(systemName: self.np.repeatMode == .one ? "repeat.1" : "repeat")
                        .scaledSystemFont(size: 13, weight: .medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.np.repeatMode == .off ? .white.opacity(0.6) : AccentPalette.color(for: self.accentColorKey))
                .help(L10n.string("Repeat: \(self.repeatModeLabel) — click to cycle"))
                .accessibilityLabel(L10n.string("Repeat \(self.repeatModeLabel)"))
                .accessibilityAddTraits(.isToggle)

                Button {
                    Task { await self.np.toggleStopAfterCurrent() }
                } label: {
                    Image(systemName: "stop.circle\(self.np.stopAfterCurrent ? ".fill" : "")")
                        .scaledSystemFont(size: 13, weight: .medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.np.stopAfterCurrent ? AccentPalette.color(for: self.accentColorKey) : .white.opacity(0.6))
                .help(self.np.stopAfterCurrent
                    ? L10n.string("Stop after current track: On")
                    : L10n.string("Stop after current track: Off"))
                .accessibilityLabel(self.np.stopAfterCurrent
                    ? L10n.string("Stop After Current: On")
                    : L10n.string("Stop After Current: Off"))
                .accessibilityAddTraits(.isToggle)
            }
        }
    }
}
