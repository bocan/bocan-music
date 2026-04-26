import SwiftUI

// MARK: - MiniPlayerCompact

/// Horizontal compact layout: thumbnail | title+artist | transport+scrubber.
/// Used when width ≥ 300 and height < 220.
struct MiniPlayerCompact: View {
    @ObservedObject var vm: MiniPlayerViewModel

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
        HStack(spacing: 14) {
            Button {
                Task { await self.np.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .accessibilityLabel("Previous")

            Button {
                Task { await self.np.playPause() }
            } label: {
                Image(systemName: self.np.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .accessibilityLabel(self.np.isPlaying ? "Pause" : "Play")

            Button {
                Task { await self.np.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .accessibilityLabel("Next")
        }
    }

    private var scrubberStack: some View {
        VStack(spacing: 2) {
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
            .frame(width: 80)
            .disabled(self.np.duration == 0)
            .accessibilityLabel("Playback position")

            HStack {
                Text(Formatters.duration(self.np.position))
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
