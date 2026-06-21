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
    @AppStorage("appearance.reduceMotion") private var appReduceMotion = false
    @State private var dragPosition: Double?
    @State private var overlayTrigger = 0

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

            // Hover-revealed mode/palette steppers, top-left. The mini player's own
            // chrome pill (layout / pin / dismiss) sits at the top-right, so the
            // steppers go on the left to stay clear of it. Only shown when the live
            // visualizer is running (reduce motion shows a static tint instead).
            if !self.reduceMotion {
                VisualizerControlOverlay(
                    vm: self.visualizerVM,
                    reduceMotion: self.reduceMotion,
                    compact: true,
                    refreshTrigger: self.overlayTrigger
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .onHover { _ in self.overlayTrigger += 1 }
        .onAppear { self.visualizerVM.start() }
        .onDisappear { self.visualizerVM.stop() }
    }

    // MARK: - Controls

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
            MiniPlayerTransport(
                np: self.np,
                musicLayout: .full,
                palette: .onVisualizer,
                openInfoWindow: { self.openWindow(id: "track-info") },
                spacing: 16,
                secondarySize: 16,
                primarySize: 22,
                accentSize: 13
            )
        }
    }
}
