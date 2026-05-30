import SwiftUI

// MARK: - MiniPlayerVisualizer

/// Square visualizer layout: the active visualizer fills the background
/// instead of album artwork, with the same gradient-and-controls overlay
/// as `MiniPlayerSquare`.
struct MiniPlayerVisualizer: View {
    @ObservedObject var vm: MiniPlayerViewModel
    @EnvironmentObject private var visualizerVM: VisualizerViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("appearance.accentColor") private var accentColorKey = "system"
    @AppStorage("appearance.reduceMotion") private var appReduceMotion = false
    @State private var dragPosition: Double?

    private var reduceMotion: Bool {
        self.systemReduceMotion || self.appReduceMotion
    }

    private var np: NowPlayingViewModel {
        self.vm.nowPlaying
    }

    private var trackSubtitle: String? {
        let parts = [self.np.artist, self.np.album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " – ")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-bleed visualizer background — replaced with a static tint when reduce-motion is on.
            if self.reduceMotion {
                Color.bgSecondary
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            } else {
                VisualizerHost(vm: self.visualizerVM)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }

            // Overlay gradient + controls (identical to MiniPlayerSquare)
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
        .onAppear { self.visualizerVM.start() }
        .onDisappear { self.visualizerVM.stop() }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 6) {
            // Title + artist – album (white text on dark gradient)
            VStack(spacing: 2) {
                MarqueeText(
                    self.np.title.isEmpty ? "Not playing" : self.np.title,
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
            .help("Scrub to position")
            .accessibilityLabel("Playback position")

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
                .help("Get info for current track")
                .accessibilityLabel("Track Info")

                Button {
                    Task { await self.np.previous() }
                } label: {
                    Image(systemName: "backward.fill")
                        .scaledSystemFont(size: 16, weight: .semibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help("Within first 3 seconds: previous track · After 3 seconds: restart current track")
                .accessibilityLabel("Previous or restart")

                Button {
                    Task { await self.np.playPause() }
                } label: {
                    Image(systemName: self.np.isPlaying ? "pause.fill" : "play.fill")
                        .scaledSystemFont(size: 22, weight: .bold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help(self.np.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(self.np.isPlaying ? "Pause" : "Play")

                Button {
                    Task { await self.np.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .scaledSystemFont(size: 16, weight: .semibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help("Next track")
                .accessibilityLabel("Next")

                Button {
                    Task { await self.np.toggleShuffle() }
                } label: {
                    Image(systemName: "shuffle")
                        .scaledSystemFont(size: 13, weight: .medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.np.shuffleOn ? AccentPalette.color(for: self.accentColorKey) : .white.opacity(0.6))
                .help(self.np.shuffleOn ? "Shuffle: On — click to disable" : "Shuffle: Off — click to enable")
                .accessibilityLabel(self.np.shuffleOn ? "Shuffle On" : "Shuffle Off")
                .accessibilityAddTraits(.isToggle)

                Button {
                    Task { await self.np.cycleRepeat() }
                } label: {
                    Image(systemName: self.np.repeatMode == .one ? "repeat.1" : "repeat")
                        .scaledSystemFont(size: 13, weight: .medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.np.repeatMode == .off ? .white.opacity(0.6) : AccentPalette.color(for: self.accentColorKey))
                .help("Repeat: \(self.np.repeatMode == .off ? "Off" : self.np.repeatMode == .all ? "All" : "One") — click to cycle")
                .accessibilityLabel("Repeat \(self.np.repeatMode == .off ? "Off" : self.np.repeatMode == .all ? "All" : "One")")
                .accessibilityAddTraits(.isToggle)

                Button {
                    Task { await self.np.toggleStopAfterCurrent() }
                } label: {
                    Image(systemName: "stop.circle\(self.np.stopAfterCurrent ? ".fill" : "")")
                        .scaledSystemFont(size: 13, weight: .medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.np.stopAfterCurrent ? AccentPalette.color(for: self.accentColorKey) : .white.opacity(0.6))
                .help(self.np.stopAfterCurrent ? "Stop after current track: On" : "Stop after current track: Off")
                .accessibilityLabel(self.np.stopAfterCurrent ? "Stop After Current: On" : "Stop After Current: Off")
                .accessibilityAddTraits(.isToggle)
            }
        }
    }
}
