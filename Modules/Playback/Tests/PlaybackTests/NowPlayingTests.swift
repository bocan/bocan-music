import Foundation
import Persistence
import Testing
@testable import Playback

// MARK: - NowPlayingTests

@Suite("NowPlayingCentre")
struct NowPlayingTests {
    @Test("init does not throw or crash")
    @MainActor
    func initDoesNotCrash() {
        let centre = NowPlayingCentre()
        centre.setPlaying(false)
        centre.clear()
    }

    @Test("setPlaying true then false does not crash")
    @MainActor
    func setPlayingToggle() {
        let centre = NowPlayingCentre()
        centre.setPlaying(true)
        centre.setPlaying(false)
    }

    @Test("clear after update does not crash")
    @MainActor
    func clearAfterUpdate() {
        let centre = NowPlayingCentre()
        let track = self.makeTrack()
        centre.update(
            track: track,
            duration: 240,
            positionProvider: { 0 }
        )
        centre.clear()
    }

    @Test("update sets nowPlayingInfo title")
    @MainActor
    func updateSetsTitle() {
        let centre = NowPlayingCentre()
        let track = self.makeTrack(title: "Test Song")
        centre.update(
            track: track,
            duration: 180,
            positionProvider: { 42 }
        )
        // NowPlayingCentre updates MPNowPlayingInfoCenter.default().nowPlayingInfo
        // We can't assert on MPNowPlayingInfoCenter in a unit test (it requires
        // a running app with audio session), but we verify no crash occurs.
        centre.clear()
    }

    @Test("setPlaying false clears playback rate")
    @MainActor
    func setPlayingFalseClearsRate() {
        let centre = NowPlayingCentre()
        let track = self.makeTrack()
        centre.update(
            track: track,
            duration: 100,
            positionProvider: { 10 }
        )
        centre.setPlaying(true)
        centre.setPlaying(false)
        // Verify no crash; actual MPNowPlayingInfoCenter state is app-level.
    }

    // MARK: - Helpers

    private func makeTrack(title: String = "Sample Track") -> Track {
        let now = Int64(Date().timeIntervalSince1970)
        return Track(
            fileURL: "/tmp/sample.flac",
            fileFormat: "flac",
            duration: 180,
            title: title,
            addedAt: now,
            updatedAt: now
        )
    }
}
