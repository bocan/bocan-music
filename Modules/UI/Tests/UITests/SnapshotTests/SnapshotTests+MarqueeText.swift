import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import UI

// MARK: - MarqueeText Snapshots

extension UISnapshotTests {
    @Suite("MarqueeText Snapshots")
    @MainActor
    struct MarqueeTextSnapshotTests {
        // A title long enough to overflow a 200-pt column.
        private static let longTitle = "Here Comes the Sun (Remastered 2009) — The Beatles — Abbey Road"
        private static let shortTitle = "Abbey Road"
        private static let size = CGSize(width: 200, height: 20)

        @Test("MarqueeText static overflow light mode")
        func staticOverflowLight() {
            let view = MarqueeText(
                Self.longTitle,
                font: .system(size: 12, weight: .semibold),
                foregroundStyle: Color.primary
            )
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(\.marqueeReduceMotion, true)
            assertSnapshot(
                of: host(view, size: Self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "marquee-static-overflow-light"
            )
        }

        @Test("MarqueeText static overflow dark mode")
        func staticOverflowDark() {
            let view = MarqueeText(
                Self.longTitle,
                font: .system(size: 12, weight: .semibold),
                foregroundStyle: Color.primary
            )
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(\.marqueeReduceMotion, true)
            .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: Self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "marquee-static-overflow-dark"
            )
        }

        @Test("MarqueeText static fit light mode")
        func staticFitLight() {
            let view = MarqueeText(
                Self.shortTitle,
                font: .system(size: 12, weight: .semibold),
                foregroundStyle: Color.primary
            )
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(\.marqueeReduceMotion, true)
            assertSnapshot(
                of: host(view, size: Self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "marquee-static-fit-light"
            )
        }

        @Test("MarqueeText static fit dark mode")
        func staticFitDark() {
            let view = MarqueeText(
                Self.shortTitle,
                font: .system(size: 12, weight: .semibold),
                foregroundStyle: Color.primary
            )
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(\.marqueeReduceMotion, true)
            .colorScheme(.dark)
            assertSnapshot(
                of: host(view, size: Self.size),
                as: .image(precision: 0.98, perceptualPrecision: 0.98),
                named: "marquee-static-fit-dark"
            )
        }
    }
}
