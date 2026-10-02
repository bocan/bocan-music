import Foundation
import Persistence
import Testing
@testable import Podcasts

@Suite("PodcastService - playback state", .serialized)
struct PodcastServicePlaybackTests {
    // MARK: resumePosition

    @Test("resumePosition returns saved position when inProgress")
    func resumePositionInProgress() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)
        let stateRepo = EpisodeStateRepository(database: bed.db)
        try await stateRepo.savePosition(
            podcastID: podcastID,
            guid: ep1GUID,
            position: 120,
            now: fixedNow.timeIntervalSince1970
        )

        let pos = await bed.service.resumePosition(feedURL: testFeedURL, episodeGUID: ep1GUID)
        #expect(pos == 120)
    }

    @Test("resumePosition returns 0 when play_state is played")
    func resumePositionPlayed() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)
        let stateRepo = EpisodeStateRepository(database: bed.db)
        try await stateRepo.markPlayed(
            podcastID: podcastID,
            guid: ep1GUID,
            now: fixedNow.timeIntervalSince1970
        )

        let pos = await bed.service.resumePosition(feedURL: testFeedURL, episodeGUID: ep1GUID)
        #expect(pos == 0)
    }

    @Test("resumePosition returns 0 when within completionTailSeconds of duration")
    func resumePositionNearEnd() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        // Episode 1 has duration 3723s. Position 3710 is 13s from the end (< 15s tail).
        let stateRepo = EpisodeStateRepository(database: bed.db)
        try await stateRepo.savePosition(
            podcastID: podcastID,
            guid: ep1GUID,
            position: 3710,
            now: fixedNow.timeIntervalSince1970
        )

        let pos = await bed.service.resumePosition(feedURL: testFeedURL, episodeGUID: ep1GUID)
        #expect(pos == 0)
    }

    // MARK: saveProgress

    @Test("saveProgress near the end auto-marks the episode played")
    func saveProgressNearEndMarksPlayed() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        // Episode 1 duration = 3723s; position 3710 triggers auto-play.
        await bed.service.saveProgress(
            feedURL: testFeedURL,
            episodeGUID: ep1GUID,
            position: 3710,
            duration: 3723
        )

        let stateRepo = EpisodeStateRepository(database: bed.db)
        let state = try await stateRepo.fetch(podcastID: podcastID, guid: ep1GUID)
        #expect(state?.playState == .played)
    }

    @Test("saveProgress with position <= 0 is a no-op")
    func saveProgressZeroIsNoOp() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        await bed.service.saveProgress(
            feedURL: testFeedURL,
            episodeGUID: ep1GUID,
            position: 0,
            duration: 3723
        )

        let stateRepo = EpisodeStateRepository(database: bed.db)
        let state = try await stateRepo.fetch(podcastID: podcastID, guid: ep1GUID)
        #expect(state == nil)
    }

    // MARK: audioURL

    @Test("audioURL returns the enclosure URL when no download exists")
    func audioURLReturnsEnclosure() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }
        _ = try await bed.service.subscribe(feedURL: testFeedURL)

        let url = try await bed.service.audioURL(feedURL: testFeedURL, episodeGUID: ep1GUID)
        #expect(url.absoluteString == "https://example.com/ep1.mp3")
    }

    @Test("audioURL returns a local file URL when a downloaded state row has an existing file")
    func audioURLReturnsLocalFile() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        // Write a temporary file to act as the downloaded episode.
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ep1-\(UUID().uuidString).mp3")
        try Data("fake audio".utf8).write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let stateRepo = EpisodeStateRepository(database: bed.db)
        try await stateRepo.setDownloadState(
            podcastID: podcastID,
            guid: ep1GUID,
            state: .downloaded,
            path: tmpFile.path,
            bytes: nil
        )

        let url = try await bed.service.audioURL(feedURL: testFeedURL, episodeGUID: ep1GUID)
        #expect(url.isFileURL)
        #expect(url.path == tmpFile.path)
    }

    @Test("audioURL resets state and streams when the downloaded file is missing")
    func audioURLResetsWhenFileMissing() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        // State claims downloaded, but the path does not exist (cleared out of band).
        let stateRepo = EpisodeStateRepository(database: bed.db)
        try await stateRepo.setDownloadState(
            podcastID: podcastID,
            guid: ep1GUID,
            state: .downloaded,
            path: "/tmp/does-not-exist-\(UUID().uuidString).mp3",
            bytes: 1234
        )

        let url = try await bed.service.audioURL(feedURL: testFeedURL, episodeGUID: ep1GUID)
        #expect(!url.isFileURL, "falls back to the streaming enclosure URL")
        #expect(url.absoluteString == "https://example.com/ep1.mp3")

        // The stale download state must be reset to none.
        let state = try await stateRepo.fetch(podcastID: podcastID, guid: ep1GUID)
        #expect(state?.downloadState == EpisodeDownloadState.none)
    }
}
