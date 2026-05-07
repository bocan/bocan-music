import SwiftUI

/// `EnvironmentValues` extension for ``MarqueeText`` accessibility overrides.
public extension EnvironmentValues {
    /// Override reduce-motion for ``MarqueeText``.
    ///
    /// Set to `true` or `false` in tests; leave `nil` (default) in production
    /// to follow the system `accessibilityReduceMotion` value.
    @Entry var marqueeReduceMotion: Bool?
}

// MARK: - MarqueeText

/// A single-line `Text` that auto-scrolls when its content overflows the
/// available width.
///
/// Behaviour:
/// - Waits ``leadDelay`` seconds (default 3 s), then scrolls the full
///   overflow distance at ``speed`` pts/second.
/// - Pauses at the end for ``tailPause`` (1 s), then snaps back and repeats.
/// - While the pointer is hovering the view resets to the start and waits.
/// - When `accessibilityReduceMotion` is `true` the text is rendered as a
///   static, truncated single line (`.tail`) — no animation.
/// - When the text fits entirely within the container no animation fires.
///
/// Usage:
/// ```swift
/// MarqueeText(track.title, font: .system(size: 12, weight: .semibold),
///             foregroundStyle: Color.textPrimary)
/// ```
public struct MarqueeText: View {
    // MARK: - Configuration

    private let text: String
    private let font: Font
    private let style: AnyShapeStyle

    // Animation constants (spec §13: 60 pt/s, 3 s lead delay)
    private static let speed: Double = 60 // pts / second
    private static let leadDelay = 3.0 // pause before first scroll
    private static let tailPause = 1.0 // pause at end of scroll
    private static let resetGap = 0.3 // gap between reset and lead

    // MARK: - State

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var isHovered = false

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.marqueeReduceMotion) private var overrideReduceMotion

    private var reduceMotion: Bool {
        self.overrideReduceMotion ?? self.systemReduceMotion
    }

    // MARK: - Init

    public init(
        _ text: String,
        font: Font = .body,
        foregroundStyle: some ShapeStyle = Color.primary
    ) {
        self.text = text
        self.font = font
        self.style = AnyShapeStyle(foregroundStyle)
    }

    // MARK: - Derived

    private var overflow: CGFloat {
        max(0, self.textWidth - self.containerWidth)
    }

    private var shouldScroll: Bool {
        !self.reduceMotion && self.overflow > 1
    }

    /// Changing this ID restarts the animation task (measurements changed,
    /// hover toggled, text changed, or scrolling need changed).
    private var animID: String {
        "\(self.text)-\(self.shouldScroll)-\(self.isHovered)-\(Int(self.overflow.rounded()))"
    }

    // MARK: - Body

    public var body: some View {
        if self.reduceMotion {
            // Static fallback: normal truncated line
            Text(self.text)
                .font(self.font)
                .foregroundStyle(self.style)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Scrolling path: always fixed-size, clipped at container edge
            Text(self.text)
                .font(self.font)
                .foregroundStyle(self.style)
                .fixedSize(horizontal: true, vertical: false)
                // Measure natural text width via background (pre-offset)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: MarqueeTextWidthKey.self, value: geo.size.width)
                    }
                )
                .offset(x: -self.offset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                // Measure container width via background (post-frame expansion)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: MarqueeContainerWidthKey.self, value: geo.size.width)
                    }
                )
                .onPreferenceChange(MarqueeTextWidthKey.self) { self.textWidth = $0 }
                .onPreferenceChange(MarqueeContainerWidthKey.self) { self.containerWidth = $0 }
                .onHover { self.isHovered = $0 }
                .task(id: self.animID) {
                    // Always reset to start when any parameter changes
                    withAnimation(.none) { self.offset = 0 }
                    guard self.shouldScroll, !self.isHovered, self.overflow > 1 else { return }
                    do {
                        // Lead-in pause
                        try await Task.sleep(for: .seconds(Self.leadDelay))
                        while !Task.isCancelled {
                            // Scroll to end
                            let duration = self.overflow / Self.speed
                            withAnimation(.linear(duration: duration)) { self.offset = self.overflow }
                            try await Task.sleep(for: .seconds(duration + Self.tailPause))
                            // Snap back
                            withAnimation(.none) { self.offset = 0 }
                            // Gap + re-lead before next scroll
                            try await Task.sleep(for: .seconds(Self.resetGap + Self.leadDelay))
                        }
                    } catch {
                        // CancellationError — stop animation immediately
                        withAnimation(.none) { self.offset = 0 }
                    }
                }
        }
    }
}

// MARK: - Private Preference Keys

private struct MarqueeTextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MarqueeContainerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
