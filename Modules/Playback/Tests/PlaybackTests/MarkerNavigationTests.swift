import Foundation
import Persistence
import Testing
@testable import Playback

// MARK: - MarkerNavigationTests

/// Every boundary of the ADR-087 CUE-marker transport rules. Markers at
/// 0s / 20s / 40s throughout; the restart threshold is 3s.
@Suite("MarkerNavigation")
struct MarkerNavigationTests {
    private let markers: [TrackMarker] = [
        TrackMarker(trackID: 1, positionMs: 0, title: "One"),
        TrackMarker(trackID: 1, positionMs: 20000, title: "Two"),
        TrackMarker(trackID: 1, positionMs: 40000, title: "Three"),
    ]

    // MARK: - Forward

    @Test("forward jumps to the next marker")
    func forwardJumps() {
        #expect(MarkerNavigation.nextTarget(markers: self.markers, elapsed: 5) == 20)
        #expect(MarkerNavigation.nextTarget(markers: self.markers, elapsed: 25) == 40)
    }

    @Test("forward past the last marker advances the queue")
    func forwardPastLast() {
        #expect(MarkerNavigation.nextTarget(markers: self.markers, elapsed: 45) == nil)
    }

    @Test("a jump landing on a boundary doesn't re-target the same marker")
    func forwardEpsilon() {
        #expect(MarkerNavigation.nextTarget(markers: self.markers, elapsed: 20) == 40)
    }

    @Test("no markers never yields a target")
    func forwardNoMarkers() {
        #expect(MarkerNavigation.nextTarget(markers: [], elapsed: 5) == nil)
    }

    // MARK: - Back

    @Test("a track that just started retreats to the previous queue item")
    func backJustStarted() {
        #expect(MarkerNavigation.previousAction(markers: self.markers, elapsed: 2) == .retreat)
        #expect(MarkerNavigation.previousAction(markers: [], elapsed: 2) == .retreat)
    }

    @Test("past the threshold inside a marker restarts that marker")
    func backRestartsMarker() {
        #expect(MarkerNavigation.previousAction(markers: self.markers, elapsed: 30) == .seek(20))
        #expect(MarkerNavigation.previousAction(markers: self.markers, elapsed: 50) == .seek(40))
    }

    @Test("just inside a marker goes to the previous marker")
    func backToPreviousMarker() {
        #expect(MarkerNavigation.previousAction(markers: self.markers, elapsed: 21) == .seek(0))
        #expect(MarkerNavigation.previousAction(markers: self.markers, elapsed: 42) == .seek(20))
    }

    @Test("deep in the first marker restarts the beginning")
    func backInFirstMarker() {
        #expect(MarkerNavigation.previousAction(markers: self.markers, elapsed: 10) == .seek(0))
    }

    @Test("no markers keeps track-level restart semantics")
    func backNoMarkers() {
        #expect(MarkerNavigation.previousAction(markers: [], elapsed: 10) == .seek(0))
    }
}
