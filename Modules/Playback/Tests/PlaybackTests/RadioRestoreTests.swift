import Foundation
import Testing
@testable import AudioEngine
@testable import Persistence
@testable import Playback

// MARK: - Radio queue restore (phase 27 regression)

/// Restoring a persisted queue whose current item is a live radio stream must
/// not pre-load or seek it. The original bug: launch restore seeked the live
/// stream to the saved position, FFmpeg degraded that into reading the stream
/// at the server's pace, and the held transport gate starved every subsequent
/// play (songs included) until the app was killed.
@Suite("Radio queue restore")
struct RadioRestoreTests {
    private func makeRadioItem(url: URL) -> QueueItem {
        let fmt = AudioSourceFormat(
            sampleRate: 44100,
            bitDepth: 16,
            channelCount: 2,
            isInterleaved: false,
            codec: "stream"
        )
        return QueueItem(
            trackID: -1,
            bookmark: nil,
            fileURL: url.absoluteString,
            duration: 0,
            sourceFormat: fmt,
            title: "Test FM",
            artistName: "Internet Radio",
            albumName: nil,
            genre: nil,
            playableSource: .internetRadio(streamURL: url)
        )
    }

    @Test("restore keeps the queue rows but never loads or seeks a live stream")
    func restoreSkipsLiveStreamResume() async throws {
        let db = try await Database(location: .inMemory)
        // Nothing listens on this URL; if the restore path ever tries to open
        // it the engine leaves .idle, which the final assertion catches.
        let streamURL = try #require(URL(string: "https://127.0.0.1:9/never"))

        let persistence = QueuePersistence(database: db, debounce: .milliseconds(10))
        await persistence.scheduleSave(
            items: [self.makeRadioItem(url: streamURL)],
            currentIndex: 0,
            repeatMode: .off,
            shuffleState: .off
        )
        await persistence._awaitPendingSaveForTesting()

        UserDefaults.standard.set(412.0, forKey: "playback.resumePosition")
        defer { UserDefaults.standard.removeObject(forKey: "playback.resumePosition") }

        let engine = AudioEngine()
        let player = QueuePlayer(engine: engine, database: db)

        // Activation (and the restore inside it) runs detached from init;
        // poll until the queue lands rather than sleeping a guessed window.
        var restored: QueueItem?
        for _ in 0 ..< 200 {
            if let item = await player.queue.currentItem {
                restored = item
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        #expect(restored?.playableSource.isLiveStream == true, "queue rows must still restore")
        #expect(
            UserDefaults.standard.object(forKey: "playback.resumePosition") == nil,
            "the stale resume position must be consumed, not left to re-trigger"
        )
        // The discriminator: a load attempt would move the engine to .loading
        // (then .ready or .failed). The skip leaves it untouched.
        #expect(await engine._state == PlaybackState.idle, "restore must not touch a live stream")
        #expect(await engine.currentURL == nil)
    }

    @Test("a restored radio item is not marked unavailable")
    func restoredRadioItemIsNotMarkedMissing() async throws {
        let db = try await Database(location: .inMemory)
        let streamURL = try #require(URL(string: "https://127.0.0.1:9/never"))

        let persistence = QueuePersistence(database: db, debounce: .milliseconds(10))
        await persistence.scheduleSave(
            items: [self.makeRadioItem(url: streamURL)],
            currentIndex: 0,
            repeatMode: .off,
            shuffleState: .off
        )
        await persistence._awaitPendingSaveForTesting()

        let engine = AudioEngine()
        let player = QueuePlayer(engine: engine, database: db)
        await player.waitUntilActivated()

        // The availability sweep runs inside restore. A remote URL's `.path`
        // ("/never") does not exist on disk; the sweep must skip non-file
        // sources instead of flagging the station "(missing)" and disabling
        // its Up Next row.
        #expect(await player.queue.currentItem != nil, "queue rows must restore")
        #expect(await player.unavailableItemIDs().isEmpty, "a live stream must never be marked missing")
    }
}
