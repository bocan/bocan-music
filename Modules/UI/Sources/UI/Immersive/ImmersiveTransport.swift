import SwiftUI

// MARK: - ImmersiveTransport

/// The player controls at the foot of the Immersive Mode now-playing column
/// (ADR-089): a full-width scrubber with elapsed and total time, the shared
/// transport row (``MiniPlayerTransport``, podcast-aware), and a volume
/// control. The strip is covered while Immersive Mode is on, so this is the
/// only transport on screen; every control carries its own identifier.
struct ImmersiveTransport: View {
    /// `@Observable`, so a plain property is the correct binding.
    var np: NowPlayingViewModel

    /// While dragging the scrubber the fraction is held locally so the
    /// slider does not fight the engine's position ticks.
    @State private var dragPosition: Double?
    @AppStorage("appearance.accentColor") private var accentColorKey = "system"

    var body: some View {
        VStack(spacing: 10) {
            self.scrubber
            HStack(spacing: 12) {
                MiniPlayerTransport(
                    np: self.np,
                    musicLayout: .navigation,
                    palette: .standard,
                    identifiers: .init(
                        previous: A11y.Immersive.previous,
                        playPause: A11y.Immersive.playPause,
                        next: A11y.Immersive.next,
                        shuffle: A11y.Immersive.shuffle,
                        repeatMode: A11y.Immersive.repeatMode,
                        stopAfter: A11y.Immersive.stopAfter,
                        skipBack: A11y.Immersive.skipBack,
                        skipForward: A11y.Immersive.skipForward
                    ),
                    spacing: 14,
                    secondarySize: 18,
                    primarySize: 28,
                    accentSize: 14
                )
                Spacer(minLength: 8)
                self.volume
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.Immersive.transport)
    }

    // MARK: - Scrubber

    private var scrubber: some View {
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
            .controlSize(.small)
            .id(self.accentColorKey)
            .disabled(self.np.duration == 0)
            .help(L10n.string("Scrub to position"))
            .accessibilityLabel(L10n.string("Playback position"))
            .accessibilityIdentifier(A11y.Immersive.scrubber)

            HStack {
                Text(Formatters.duration(self.dragPosition.map { $0 * self.np.duration } ?? self.np.position))
                Spacer()
                Text(Formatters.duration(self.np.duration))
            }
            .font(Typography.caption)
            .foregroundStyle(Color.textTertiary)
            .monospacedDigit()
        }
    }

    // MARK: - Volume

    private var volume: some View {
        HStack(spacing: 4) {
            Button {
                Task { await self.np.toggleMute() }
            } label: {
                Image(systemName: self.np.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(Typography.caption)
                    .foregroundStyle(self.np.isMuted ? Color.textPrimary : Color.textTertiary)
            }
            .buttonStyle(.plain)
            .help(self.np.isMuted ? L10n.string("Unmute") : L10n.string("Mute"))
            .accessibilityLabel(self.np.isMuted ? L10n.string("Unmute") : L10n.string("Mute"))
            .accessibilityIdentifier(A11y.Immersive.mute)

            Slider(value: Binding(
                get: { Double(self.np.volume) },
                set: { newVolume in Task { await self.np.setVolume(Float(newVolume)) } }
            ), in: 0 ... 1) { editing in
                if !editing { Haptics.positionCommit() }
            }
            .controlSize(.mini)
            .frame(width: 90)
            .id(self.accentColorKey)
            .help(L10n.string("Volume: \(Int(self.np.volume * 100))%"))
            .accessibilityLabel(L10n.string("Volume"))
            .accessibilityValue(L10n.string("\(Int(self.np.volume * 100)) percent"))
            .accessibilityAdjustableAction { direction in
                guard direction == .increment || direction == .decrement else { return }
                let vol = direction == .increment ? min(self.np.volume + 0.1, 1) : max(self.np.volume - 0.1, 0)
                Task { await self.np.setVolume(vol) }
            }
            .accessibilityIdentifier(A11y.Immersive.volume)
        }
    }
}
