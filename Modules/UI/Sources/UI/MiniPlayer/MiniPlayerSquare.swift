import AppKit
import SwiftUI

// MARK: - MiniPlayerSquare

/// Square artwork-first layout: used when width ≥ 220 and height ≥ 220.
struct MiniPlayerSquare: View {
    @ObservedObject var vm: MiniPlayerViewModel
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var dragPosition: Double?

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
