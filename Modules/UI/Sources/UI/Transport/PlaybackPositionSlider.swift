import SwiftUI

// MARK: - PlaybackPositionSlider

/// The playback-position slider every surface shows: the strip, the three
/// mini player layouts, Immersive and the menu bar extra (#723).
///
/// It owns what the six copies used to repeat: the drag fraction held while
/// the thumb moves (so live position updates do not fight it), the seek on
/// release through ``ScrubberDrag`` (#710), the disabled state with no
/// duration, the hover text, and the VoiceOver label, value and step
/// actions. A surface passes only what differs, and arranges the result in
/// `layout`, which receives the slider and the position to show beside it:
/// the live position, or the drag's while the thumb is held.
struct PlaybackPositionSlider<Layout: View>: View {
    var nowPlaying: NowPlayingViewModel
    var style: PositionSliderStyle
    let layout: (PositionSliderControl, TimeInterval) -> Layout

    @State private var dragFraction: Double?

    init(
        nowPlaying: NowPlayingViewModel,
        style: PositionSliderStyle = PositionSliderStyle(),
        @ViewBuilder layout: @escaping (PositionSliderControl, TimeInterval) -> Layout
    ) {
        self.nowPlaying = nowPlaying
        self.style = style
        self.layout = layout
    }

    var body: some View {
        let position = PositionSliderControl.displayPosition(
            dragFraction: self.dragFraction,
            position: self.nowPlaying.position,
            duration: self.nowPlaying.duration
        )
        self.layout(
            PositionSliderControl(
                nowPlaying: self.nowPlaying,
                dragFraction: self.$dragFraction,
                displayPosition: position,
                style: self.style
            ),
            position
        )
    }
}

extension PlaybackPositionSlider where Layout == PositionSliderControl {
    /// The slider on its own, for a surface that shows no time labels.
    init(nowPlaying: NowPlayingViewModel, style: PositionSliderStyle = PositionSliderStyle()) {
        self.init(nowPlaying: nowPlaying, style: style) { control, _ in control }
    }
}

// MARK: - PositionSliderStyle

/// What differs between the surfaces' sliders.
struct PositionSliderStyle {
    var controlSize: ControlSize = .mini
    /// Nil keeps the app's accent colour.
    var tint: Color?
    /// Hover text. The menu bar extra words it for a menu.
    var help = L10n.string("Scrub to position")
    var accessibilityIdentifier: String?
    /// A value whose change rebuilds the slider: the accent colour key, for
    /// a slider drawn in the accent colour, which AppKit does not redraw
    /// when the accent changes. Nil never rebuilds it.
    var rebuildKey: String?
}

// MARK: - PositionSliderControl

/// The slider itself, as `PlaybackPositionSlider` hands it to a layout.
struct PositionSliderControl: View {
    var nowPlaying: NowPlayingViewModel
    @Binding var dragFraction: Double?
    let displayPosition: TimeInterval
    let style: PositionSliderStyle

    var body: some View {
        Slider(
            value: Binding(
                get: {
                    Self.fraction(
                        dragFraction: self.dragFraction,
                        position: self.nowPlaying.position,
                        duration: self.nowPlaying.duration
                    )
                },
                // Hold the drag locally; seek once on release, not per move.
                set: { self.dragFraction = $0 }
            ),
            in: 0 ... 1
        ) { editing in
            if !editing {
                Task { await ScrubberDrag.release(self.$dragFraction, nowPlaying: self.nowPlaying) }
            }
        }
        .controlSize(self.style.controlSize)
        .tint(self.style.tint)
        .disabled(self.nowPlaying.duration == 0)
        .id(self.style.rebuildKey)
        .help(self.style.help)
        .accessibilityLabel(L10n.string("Playback position"))
        .accessibilityValue(
            L10n.string(
                "\(Formatters.duration(self.displayPosition)) of \(Formatters.duration(self.nowPlaying.duration))"
            )
        )
        .accessibilityAdjustableAction { direction in
            guard direction == .increment || direction == .decrement else { return }
            let target = Self.steppedPosition(
                increment: direction == .increment,
                position: self.nowPlaying.position,
                duration: self.nowPlaying.duration
            )
            Task { await self.nowPlaying.scrub(to: target) }
        }
        .modifier(OptionalAccessibilityIdentifier(identifier: self.style.accessibilityIdentifier))
    }

    /// The thumb's place: the drag while it is held, else the live position.
    static func fraction(dragFraction: Double?, position: TimeInterval, duration: TimeInterval) -> Double {
        dragFraction ?? (duration > 0 ? position / duration : 0)
    }

    /// The time to show beside the slider: where the thumb is while it is
    /// dragged, else the live position.
    static func displayPosition(dragFraction: Double?, position: TimeInterval, duration: TimeInterval) -> TimeInterval {
        dragFraction.map { $0 * duration } ?? position
    }

    /// Where a VoiceOver step moves to: 5% of the track or 5 seconds,
    /// whichever is longer, kept inside the track.
    static func steppedPosition(increment: Bool, position: TimeInterval, duration: TimeInterval) -> TimeInterval {
        let step = max(duration * 0.05, 5)
        return increment ? min(position + step, duration) : max(position - step, 0)
    }
}

// MARK: - OptionalAccessibilityIdentifier

/// Sets the identifier only when there is one, so a surface whose slider
/// never had an identifier does not gain an empty one.
private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier = self.identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
