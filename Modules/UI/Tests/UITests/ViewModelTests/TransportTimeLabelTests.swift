import AppKit
import Foundation
import Testing
@testable import UI

/// The transport time labels either side of the scrubber are fixed-width, so
/// the slider does not shift as the clock ticks. That makes the slot a promise:
/// it must fit every string `Formatters.duration` can hand it. It did not for
/// anything over an hour, and SwiftUI wrapped the last digit onto a second line
/// (#563), which is what a listener saw on a long podcast.
@Suite("Transport time labels")
struct TransportTimeLabelTests {
    /// The rendered width of `text` in what SwiftUI draws for
    /// `Typography.caption` plus `.monospacedDigit()`. The font is built per
    /// call: `NSFont` is not `Sendable`, so it cannot be held in a `static let`
    /// under Swift 6 strict concurrency.
    private static func rendered(_ text: String) -> Double {
        let size = NSFont.preferredFont(forTextStyle: .caption1).pointSize
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: - The slot fits what the formatter produces

    /// The regression proper: every label a listener can see must fit the slot
    /// the view gives it. A three-minute song, an hour-long podcast, a
    /// feature-length concert film and a ten-hour audiobook.
    @Test(
        "Every duration fits its slot",
        arguments: [0.0, 59, 331, 3599, 3600, 3723, 7384, 35999, 36123]
    )
    func durationFitsItsSlot(seconds: Double) {
        let text = Formatters.duration(seconds)
        let slot = Formatters.timeLabelWidth(longest: seconds)
        #expect(
            Self.rendered(text) <= slot,
            "\"\(text)\" renders \(Self.rendered(text))pt into a \(slot)pt slot, so it wraps"
        )
    }

    /// The placeholder for an unknown position has to fit too.
    @Test("The unknown-time placeholder fits")
    func placeholderFits() {
        #expect(Formatters.duration(-1) == "-:--")
        #expect(Self.rendered("-:--") <= Formatters.timeLabelWidth(longest: -1))
    }

    // MARK: - The slot only widens when it has to

    /// The strip is tight: the comment on `volumeAndScrubber` records that the
    /// slider is squeezed at a narrow window. So a song under an hour must not
    /// pay for the hours column.
    @Test("Under an hour keeps the narrow slot")
    func shortContentKeepsTheNarrowSlot() {
        #expect(Formatters.timeLabelWidth(longest: 0) == 36)
        #expect(Formatters.timeLabelWidth(longest: 331) == 36)
        #expect(Formatters.timeLabelWidth(longest: 3599) == 36)
    }

    @Test("An hour and over gets the wide slot")
    func longContentGetsTheWideSlot() {
        #expect(Formatters.timeLabelWidth(longest: 3600) == 48)
        #expect(Formatters.timeLabelWidth(longest: 3723) == 48)
        #expect(Formatters.timeLabelWidth(longest: 36123) == 48)
    }

    /// A stream reports no duration, so a NaN or infinite reading must not
    /// widen the slot or crash the comparison.
    @Test("A non-finite reading falls back to the narrow slot")
    func nonFiniteFallsBack() {
        #expect(Formatters.timeLabelWidth(longest: .nan) == 36)
        #expect(Formatters.timeLabelWidth(longest: .infinity) == 36)
    }

    // MARK: - The view asks the right question

    /// `NowPlayingStrip` must size on the longer of the total and the elapsed
    /// time, not on the position alone. A live stream reports no duration, so
    /// only the elapsed reading tells the slot an hour has passed; sizing on
    /// the total alone would leave radio wrapping after an hour.
    @Test("The strip sizes on the longer of total and elapsed")
    func stripSizesOnTheLongerOfTheTwo() throws {
        let strip = try String(
            contentsOf: URL(filePath: #filePath)
                .deletingLastPathComponent() // ViewModelTests/
                .deletingLastPathComponent() // UITests/
                .deletingLastPathComponent() // Tests/
                .deletingLastPathComponent() // Modules/UI/
                .appendingPathComponent("Sources/UI/AppRoot/NowPlayingStrip.swift"),
            encoding: .utf8
        )
        #expect(strip.contains("Formatters.timeLabelWidth(longest: max(self.vm.duration, self.displayPosition))"))
        // Both labels take the computed slot, and neither keeps a literal one.
        #expect(strip.contains("frame(width: self.timeLabelWidth, alignment: .trailing)"))
        #expect(strip.contains("frame(width: self.timeLabelWidth, alignment: .leading)"))
    }
}
