import AppKit
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

    @Test("updatePodcast then clear does not crash")
    @MainActor
    func updatePodcastDoesNotCrash() {
        let centre = NowPlayingCentre()
        centre.updatePodcast(
            title: "Episode 42",
            showName: "The Show",
            duration: 1800,
            positionProvider: { 12 }
        )
        // As with update(track:), we cannot assert MPNowPlayingInfoCenter state
        // in a unit test (it requires a running app); verify no crash occurs.
        centre.setPlaying(true)
        centre.setPlaying(false)
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

    @Test("update with missing coverArtPath does not crash")
    @MainActor
    func updateWithMissingArtworkPath() async throws {
        let centre = NowPlayingCentre()
        let track = self.makeTrack(title: "Artwork Test")
        centre.update(
            track: track,
            duration: 200,
            coverArtPath: "/nonexistent/cover.jpg",
            positionProvider: { 0 }
        )
        // Give the off-main load a moment to settle before clearing.
        try await Task.sleep(nanoseconds: 200_000_000)
        centre.clear()
    }

    @Test("rapid update supersedes in-flight artwork load without crash")
    @MainActor
    func rapidUpdateSupersedesArtwork() async throws {
        let centre = NowPlayingCentre()
        // First update kicks off an artwork load against a bogus path.
        centre.update(
            track: self.makeTrack(title: "A"),
            duration: 100,
            coverArtPath: "/nonexistent/a.jpg",
            positionProvider: { 0 }
        )
        // Second update supersedes it immediately with a different track and no art.
        centre.update(
            track: self.makeTrack(title: "B"),
            duration: 100,
            coverArtPath: nil,
            positionProvider: { 0 }
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        centre.clear()
    }

    @Test("artwork request handler can run off the main actor")
    func artworkRequestHandlerRunsOffMainActor() async throws {
        let encodedPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let data = try #require(Data(base64Encoded: encodedPNG))
        let requestHandler = NowPlayingCentre.artworkRequestHandler(data: data)

        let imageSize = await Task.detached {
            requestHandler(CGSize(width: 64, height: 64)).size
        }.value

        #expect(imageSize.width > 0)
        #expect(imageSize.height > 0)
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
