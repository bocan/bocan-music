import SwiftUI

// MARK: - NowPlayingStrip

/// The 72pt-tall transport bar anchored at the bottom of every main view.
///
/// Shows current track artwork, title/artist/album, play/pause and scrubber,
/// and a volume slider.  Prev/Next buttons are present but disabled until
/// Phase 5 introduces the queue.
public struct NowPlayingStrip: View {
    @ObservedObject public var vm: NowPlayingViewModel

    public init(vm: NowPlayingViewModel) {
        self.vm = vm
    }

    public var body: some View {
        HStack(spacing: 12) {
            self.artwork
            self.trackInfo
            Spacer(minLength: 16)
            self.transport
            Spacer(minLength: 16)
            self.volumeAndScrubber
        }
        .frame(height: Theme.nowPlayingStripHeight)
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.NowPlaying.strip)
    }

    // MARK: - Sub-views

    private var artwork: some View {
        Group {
            if let img = vm.artwork {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.artworkCornerRadius, style: .continuous))
                    .accessibilityLabel("\(self.vm.album) by \(self.vm.artist)")
            } else {
                GradientPlaceholder(seed: 0)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.artworkCornerRadius, style: .continuous))
                    .accessibilityLabel("No artwork")
            }
        }
        .accessibilityIdentifier(A11y.NowPlaying.artwork)
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.vm.title.isEmpty ? "Not playing" : self.vm.title)
                .font(Typography.body)
                .foregroundStyle(self.vm.title.isEmpty ? Color.textSecondary : Color.textPrimary)
                .lineLimit(1)
                .accessibilityIdentifier(A11y.NowPlaying.title)

            if !self.vm.artist.isEmpty {
                Text(self.vm.artist)
                    .font(Typography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .accessibilityIdentifier(A11y.NowPlaying.artist)
            }
        }
        .frame(minWidth: 120, maxWidth: 220, alignment: .leading)
    }

    private var transport: some View {
        HStack(spacing: 20) {
            Button {
                Task { await self.vm.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .accessibilityLabel("Previous")
            .accessibilityIdentifier(A11y.NowPlaying.prevButton)

            Button {
                Task { await self.vm.playPause() }
            } label: {
                Image(systemName: self.vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .keyboardShortcut(KeyBindings.playPause)
            .accessibilityLabel(self.vm.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier(A11y.NowPlaying.playPauseButton)

            Button {
                Task { await self.vm.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textPrimary)
            .accessibilityLabel("Next")
            .accessibilityIdentifier(A11y.NowPlaying.nextButton)

            Button {
                Task { await self.vm.toggleShuffle() }
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.shuffleOn ? Color.accentColor : Color.textTertiary)
            .accessibilityLabel(self.vm.shuffleOn ? "Shuffle On" : "Shuffle Off")

            Button {
                Task { await self.vm.cycleRepeat() }
            } label: {
                Image(systemName: self.vm.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.repeatMode == .off ? Color.textTertiary : Color.accentColor)
            .accessibilityLabel("Repeat \(self.vm.repeatMode == .off ? "Off" : self.vm.repeatMode == .all ? "All" : "One")")

            Button {
                Task { await self.vm.toggleStopAfterCurrent() }
            } label: {
                Image(systemName: "stop.circle\(self.vm.stopAfterCurrent ? ".fill" : "")")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(self.vm.stopAfterCurrent ? Color.accentColor : Color.textTertiary)
            .accessibilityLabel(self.vm.stopAfterCurrent ? "Stop After Current: On" : "Stop After Current: Off")
        }
    }

    private var volumeAndScrubber: some View {
        VStack(spacing: 4) {
            self.scrubber
            self.volumeRow
        }
        .frame(maxWidth: 340)
    }

    private var scrubber: some View {
        HStack(spacing: 6) {
            Text(Formatters.duration(self.vm.position))
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { self.vm.duration > 0 ? self.vm.position / self.vm.duration : 0 },
                    set: { fraction in
                        Task { await self.vm.scrub(to: fraction * self.vm.duration) }
                    }
                ),
                in: 0 ... 1
            )
            .controlSize(.mini)
            .disabled(self.vm.duration == 0)
            .accessibilityLabel("Playback position")
            .accessibilityIdentifier(A11y.NowPlaying.scrubber)

            Text(Formatters.duration(self.vm.duration))
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .monospacedDigit()
                .frame(width: 36, alignment: .leading)
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "speaker.fill")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
                .accessibilityHidden(true)

            Slider(value: Binding(
                get: { Double(self.vm.volume) },
                set: { newVolume in Task { await self.vm.setVolume(Float(newVolume)) } }
            ), in: 0 ... 1)
                .controlSize(.mini)
                .frame(maxWidth: 100)
                .accessibilityLabel("Volume")
                .accessibilityIdentifier(A11y.NowPlaying.volumeSlider)

            Image(systemName: "speaker.wave.3.fill")
                .font(Typography.caption)
                .foregroundStyle(Color.textTertiary)
                .accessibilityHidden(true)
        }
    }
}
