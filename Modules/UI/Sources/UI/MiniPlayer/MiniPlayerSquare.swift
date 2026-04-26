import SwiftUI

// MARK: - MiniPlayerSquare

/// Square artwork-first layout: used when width ≥ 220 and height ≥ 220.
struct MiniPlayerSquare: View {
    @ObservedObject var vm: MiniPlayerViewModel

    private var np: NowPlayingViewModel {
        self.vm.nowPlaying
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
            // Title + artist (white text on dark gradient)
            VStack(spacing: 2) {
                Text(self.np.title.isEmpty ? "Not playing" : self.np.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)

                if !self.np.artist.isEmpty {
                    Text(self.np.artist)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            // Thin scrubber
            Slider(
                value: Binding(
                    get: { self.np.duration > 0 ? self.np.position / self.np.duration : 0 },
                    set: { fraction in
                        Task { await self.np.scrub(to: fraction * self.np.duration) }
                    }
                ),
                in: 0 ... 1
            )
            .controlSize(.mini)
            .tint(.white)
            .disabled(self.np.duration == 0)
            .accessibilityLabel("Playback position")

            // Transport
            HStack(spacing: 20) {
                Button {
                    Task { await self.np.previous() }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel("Previous")

                Button {
                    Task { await self.np.playPause() }
                } label: {
                    Image(systemName: self.np.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel(self.np.isPlaying ? "Pause" : "Play")

                Button {
                    Task { await self.np.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel("Next")
            }
        }
    }
}
