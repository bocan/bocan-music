import SwiftUI

// MARK: - PlayingBarsIndicator

/// Animated three-bar "now playing" indicator (Winamp / Apple Music style).
///
/// Heights are driven by a sine wave so the motion looks organic without needing audio
/// input. Update rate is ~6 Hz, which is plenty for a smooth-feeling bounce while
/// staying cheap on the GPU.
///
/// When `isPlaying` is `false`, the `TimelineView` is paused and the bars freeze at
/// their current heights — no redraws, no CPU cost. When the row scrolls off-screen
/// in a `List`/`LazyVStack`, SwiftUI tears the view down entirely so the timeline
/// stops ticking automatically.
struct PlayingBarsIndicator: View {
    /// Whether the bars should animate. `false` freezes the bars in place.
    let isPlaying: Bool

    /// Tint applied to all three bars.
    var color: Color = .accentColor

    /// Total drawing size. Defaults match the surrounding 11pt SF Symbol footprint.
    var size: CGSize = .init(width: 11, height: 11)

    /// Number of full sine cycles per second. ~1.6 Hz looks natural; the *redraw*
    /// rate is set separately by `updateInterval`.
    private let frequency = 1.6

    /// Per-bar phase offsets (radians) so the three bars don't move in lockstep.
    private let phases: [Double] = [0, 2 * .pi / 3, 4 * .pi / 3]

    /// Redraw cadence — ~6 Hz per the spec.
    private let updateInterval: TimeInterval = 1.0 / 6.0

    var body: some View {
        TimelineView(.animation(minimumInterval: self.updateInterval, paused: !self.isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(0 ..< 3, id: \.self) { i in
                    let phase = self.phases[i]
                    // sin(...) ∈ [-1, 1] → height ratio ∈ [0.25, 1.0].
                    let raw = sin((t * self.frequency * 2 * .pi) + phase)
                    let ratio = self.isPlaying ? (0.25 + 0.375 * (raw + 1)) : 0.35
                    Capsule(style: .continuous)
                        .fill(self.color)
                        .frame(width: 2, height: max(2, self.size.height * ratio))
                }
            }
            .frame(width: self.size.width, height: self.size.height, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
    #Preview("Playing") {
        PlayingBarsIndicator(isPlaying: true)
            .padding()
    }

    #Preview("Paused") {
        PlayingBarsIndicator(isPlaying: false)
            .padding()
    }
#endif
