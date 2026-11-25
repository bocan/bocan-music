import Foundation
import Testing
@testable import UI

// MARK: - PlaybackPositionSliderTests

/// Every surface's progress bar is one shared view (#723). Its arithmetic is
/// tested directly; that the six surfaces use it, and keep no drag state of
/// their own, is pinned by source convention, because host-less tests cannot
/// drive a Slider.
@Suite("Playback position slider (#723)")
struct PlaybackPositionSliderTests {
    // MARK: Arithmetic

    @Test("the thumb follows the drag while held, else the live position")
    func fraction() {
        #expect(PositionSliderControl.fraction(dragFraction: 0.75, position: 30, duration: 120) == 0.75)
        #expect(PositionSliderControl.fraction(dragFraction: nil, position: 30, duration: 120) == 0.25)
        #expect(PositionSliderControl.fraction(dragFraction: nil, position: 30, duration: 0) == 0)
    }

    @Test("the time shown follows the drag while held, else the live position")
    func displayPosition() {
        #expect(PositionSliderControl.displayPosition(dragFraction: 0.5, position: 10, duration: 200) == 100)
        #expect(PositionSliderControl.displayPosition(dragFraction: nil, position: 10, duration: 200) == 10)
    }

    @Test("a VoiceOver step is 5% or 5 seconds, whichever is longer, inside the track")
    func steppedPosition() {
        // 5% of 300 s is 15 s.
        #expect(PositionSliderControl.steppedPosition(increment: true, position: 100, duration: 300) == 115)
        #expect(PositionSliderControl.steppedPosition(increment: false, position: 100, duration: 300) == 85)
        // 5% of 60 s is 3 s, so the 5 s floor applies.
        #expect(PositionSliderControl.steppedPosition(increment: true, position: 10, duration: 60) == 15)
        // Clamped to the ends.
        #expect(PositionSliderControl.steppedPosition(increment: true, position: 58, duration: 60) == 60)
        #expect(PositionSliderControl.steppedPosition(increment: false, position: 2, duration: 60) == 0)
    }

    // MARK: Wiring

    static let surfaces = [
        "Sources/UI/AppRoot/NowPlayingStrip.swift",
        "Sources/UI/MiniPlayer/MiniPlayerSquare.swift",
        "Sources/UI/MiniPlayer/MiniPlayerCompact.swift",
        "Sources/UI/MiniPlayer/MiniPlayerVisualizer.swift",
        "Sources/UI/Immersive/ImmersiveTransport.swift",
        "Sources/UI/MenuBarExtra/MenuBarExtraScene.swift",
    ]

    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("each surface shows the shared slider and keeps no drag state", arguments: surfaces)
    func surfaceUsesSharedSlider(_ path: String) throws {
        let source = try self.source(path)
        #expect(source.contains("PlaybackPositionSlider("))
        for copied in ["ScrubberDrag.release", "dragPosition", "scrubDragFraction"] {
            #expect(!source.contains(copied), "\(path) still has its own \(copied)")
        }
    }

    @Test("only the shared slider seeks on release")
    func releaseLivesInOnePlace() throws {
        let shared = try self.source("Sources/UI/Transport/PlaybackPositionSlider.swift")
        #expect(shared.contains("ScrubberDrag.release(self.$dragFraction, nowPlaying: self.nowPlaying)"))
    }

    @Test("the surfaces keep their own identifiers and hover text", arguments: [
        ("Sources/UI/AppRoot/NowPlayingStrip.swift", "accessibilityIdentifier: A11y.NowPlaying.scrubber"),
        ("Sources/UI/Immersive/ImmersiveTransport.swift", "accessibilityIdentifier: A11y.Immersive.scrubber"),
        ("Sources/UI/MenuBarExtra/MenuBarExtraScene.swift", "help: L10n.string(\"Drag to move through the track.\")"),
    ])
    func surfaceDifferencesKept(_ path: String, _ setting: String) throws {
        #expect(try self.source(path).contains(setting))
    }
}
