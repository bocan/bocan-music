import Foundation
import Persistence
import Testing
@testable import Podcasts

// MARK: - Helpers

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

/// Builds an in-memory `Database` + a `PodcastService` wired to it.
/// The `feedMock` and `artMock` are separate so artwork requests can be
/// distinguished from feed-fetch requests in tests that need the distinction.
private struct TestBed {
    let db: Database
    let service: PodcastService
    let artCache: PodcastArtworkCache
    let feedMock: MockHTTPClient
    let artMock: MockHTTPClient
    let transcriptMock: MockHTTPClient
    let artTempDir: URL
    let downloadStore: DownloadStore
    let downloadRoot: URL
}

private func makeBed(nowDate: Date = fixedNow) async throws -> TestBed {
    let db = try await Database(location: .inMemory)
    let feedMock = MockHTTPClient()
    let artMock = MockHTTPClient()
    let transcriptMock = MockHTTPClient()
    let artTemp = FileManager.default.temporaryDirectory
        .appendingPathComponent("PodcastArtworkCacheTests-\(UUID().uuidString)", isDirectory: true)
    let artCache = PodcastArtworkCache(http: artMock, root: artTemp)
    let downloadRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("PodcastDownloadsTests-\(UUID().uuidString)", isDirectory: true)
    let downloadStore = DownloadStore(root: downloadRoot)
    let service = PodcastService(
        podcastRepo: PodcastRepository(database: db),
        episodeRepo: EpisodeRepository(database: db),
        stateRepo: EpisodeStateRepository(database: db),
        transcriptRepo: TranscriptRepository(database: db),
        fetcher: FeedFetcher(http: feedMock),
        artwork: artCache,
        downloadStore: downloadStore,
        transcriptHTTP: transcriptMock,
        now: { nowDate }
    )
    return TestBed(
        db: db,
        service: service,
        artCache: artCache,
        feedMock: feedMock,
        artMock: artMock,
        transcriptMock: transcriptMock,
        artTempDir: artTemp,
        downloadStore: downloadStore,
        downloadRoot: downloadRoot
    )
}

private func fixtureData(named name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
          let data = try? Data(contentsOf: url) else {
        throw PodcastsError.parseFailed(
            url: URL(string: "test://\(name)")!,
            reason: "Fixture not found: \(name)"
        )
    }
    return data
}

private let testFeedURL = URL(string: "https://example.com/feed.rss")!
private let ep1GUID = "https://example.com/episodes/1"
private let ep2GUID = "unique-guid-ep2"

/// Polls the podcast row until `artwork_path` is non-nil (subscribe caches art on
/// a detached task), up to ~3 s. Returns the path, or nil on timeout.
private func pollArtworkPath(repo: PodcastRepository, id: Int64) async throws -> String? {
    for _ in 0 ..< 150 {
        if let path = try await repo.fetch(id: id).artworkPath { return path }
        try await Task.sleep(for: .milliseconds(20))
    }
    return nil
}

/// Polls until `path` exists on disk, up to ~3 s. Returns the final existence.
private func pollFileExists(_ path: String) async throws -> Bool {
    for _ in 0 ..< 150 {
        if FileManager.default.fileExists(atPath: path) { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return FileManager.default.fileExists(atPath: path)
}

/// Thread-safe sink for the new-episodes observer callback.
private actor ObserverCollector {
    private(set) var calls: [(id: Int64, guids: [String])] = []
    func record(id: Int64, guids: [String]) {
        self.calls.append((id, guids))
    }
}

// MARK: - Tests

@Suite("PodcastService", .serialized)
struct PodcastServiceTests {
    // MARK: Headline: refresh must never touch state rows

    @Test("Headline: refresh updates episode title but leaves play_position unchanged")
    func refreshPreservesState() async throws {
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        let refreshData = try fixtureData(named: "rss-refresh-extra.xml")

        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        // Subscribe with original feed.
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        // Save a play position for episode 1.
        let stateRepo = EpisodeStateRepository(database: bed.db)
        try await stateRepo.savePosition(
            podcastID: podcastID,
            guid: ep1GUID,
            position: 300,
            now: fixedNow.timeIntervalSince1970
        )

        let stateBefore = try await stateRepo.fetch(podcastID: podcastID, guid: ep1GUID)
        #expect(stateBefore?.playPosition == 300)

        // Refresh with updated feed (episode 1 title changed; episode 3 added).
        bed.feedMock.handler = { _ in
            (refreshData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await bed.service.refresh(podcastID: podcastID)

        // State row must be untouched.
        let stateAfter = try await stateRepo.fetch(podcastID: podcastID, guid: ep1GUID)
        #expect(stateAfter?.playPosition == 300)
        #expect(stateAfter?.playState == .inProgress)

        // Episode title must reflect the refreshed feed.
        let episodeRepo = EpisodeRepository(database: bed.db)
        let ep1 = try await episodeRepo.fetchByGUID(podcastID: podcastID, guid: ep1GUID)
        #expect(ep1?.title == "Episode 1: The Pilot (Revised)")
    }

    // MARK: subscribe

    @Test("transcript fetches once on a miss, then serves from the cache")
    func transcriptCacheFirst() async throws {
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        var requestCount = 0
        let body = "WEBVTT\n\n00:00.000 --> 00:01.000\nHello"
        bed.transcriptMock.handler = { _ in
            requestCount += 1
            return (Data(body.utf8), HTTPURLResponse(
                url: URL(string: "https://example.com/ep1-transcript.vtt")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/vtt"]
            )!)
        }

        // Episode 1 in rss-full.xml carries a podcast:transcript URL (parsed in 21-11).
        let guid = "https://example.com/episodes/1"
        let first = try await bed.service.transcript(podcastID: podcastID, guid: guid)
        let second = try await bed.service.transcript(podcastID: podcastID, guid: guid)
        #expect(first.content == body)
        #expect(first.format == .vtt)
        #expect(second.content == body)
        #expect(requestCount == 1, "second call must hit the cache, not re-fetch")
    }

    @Test("subscribe writes one podcasts row and N episode rows")
    func subscribeWritesRows() async throws {
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)
        #expect(podcastID > 0)

        let repo = PodcastRepository(database: bed.db)
        let podcast = try await repo.fetch(id: podcastID)
        #expect(podcast.title == "Full Feature Podcast")
        #expect(podcast.subscribed == true)

        let epRepo = EpisodeRepository(database: bed.db)
        let episodes = try await epRepo.fetchForPodcast(podcastID: podcastID)
        #expect(episodes.count == 2)
    }

    @Test("re-subscribing the same feed upserts and does not duplicate rows")
    func reSubscribeIsIdempotent() async throws {
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let id1 = try await bed.service.subscribe(feedURL: testFeedURL)
        let id2 = try await bed.service.subscribe(feedURL: testFeedURL)
        #expect(id1 == id2)

        let repo = PodcastRepository(database: bed.db)
        let all = try await repo.fetchAllSubscribed()
        #expect(all.count == 1)

        let epRepo = EpisodeRepository(database: bed.db)
        let episodes = try await epRepo.fetchForPodcast(podcastID: id1)
        #expect(episodes.count == 2)
    }

    @Test("index hints land in itunes_collection_id and podcast_index_id")
    func indexHintsStored() async throws {
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let hints = PodcastSearchResult(
            canonicalFeedKey: "example.com/feed.rss",
            feedURL: testFeedURL,
            title: "Full Feature Podcast",
            sources: [.itunes, .podcastIndex],
            podcastIndexID: 42,
            itunesCollectionID: 9999
        )
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL, indexHints: hints)

        let repo = PodcastRepository(database: bed.db)
        let podcast = try await repo.fetch(id: podcastID)
        #expect(podcast.podcastIndexID == 42)
        #expect(podcast.itunesCollectionID == 9999)
    }

    @Test("subscribe rejects non-http URL with invalidFeedURL")
    func subscribeRejectsInvalidURL() async throws {
        let bed = try await makeBed()
        let badURL = try #require(URL(string: "ftp://example.com/feed"))
        await #expect(throws: PodcastsError.self) {
            _ = try await bed.service.subscribe(feedURL: badURL)
        }
    }

    // MARK: refresh - 304

    @Test("refresh on 304 stamps last_refreshed_at and leaves episodes untouched")
    func refresh304() async throws {
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        // Second call returns 304.
        let refETag = "\"abc123\""
        bed.feedMock.handler = { _ in
            (Data(), HTTPURLResponse(
                url: testFeedURL,
                statusCode: 304,
                httpVersion: nil,
                headerFields: ["ETag": refETag]
            )!)
        }

        let t1 = fixedNow.addingTimeInterval(60)
        var t1Bed = bed
        _ = t1Bed // silence unused warning
        // Use a fresh service with a later `now` to detect the timestamp update.
        let lateBed = try await makeBed(nowDate: fixedNow.addingTimeInterval(60))
        let rssData2 = try fixtureData(named: "rss-full.xml")
        lateBed.feedMock.handler = { _ in
            (rssData2, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let lateID = try await lateBed.service.subscribe(feedURL: testFeedURL)

        lateBed.feedMock.handler = { _ in
            (Data(), HTTPURLResponse(url: testFeedURL, statusCode: 304, httpVersion: nil, headerFields: nil)!)
        }

        let outcome = try await lateBed.service.refresh(podcastID: lateID)
        #expect(outcome.notModified == true)

        let repo = PodcastRepository(database: lateBed.db)
        let podcast = try await repo.fetch(id: lateID)
        #expect(podcast.lastRefreshedAt == t1.timeIntervalSince1970)

        let epRepo = EpisodeRepository(database: lateBed.db)
        let episodes = try await epRepo.fetchForPodcast(podcastID: lateID)
        #expect(episodes.count == 2)
    }

    // MARK: refresh - new episode

    @Test("refresh with extra episode produces newEpisodeCount == 1")
    func refreshNewEpisode() async throws {
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        let extraData = try fixtureData(named: "rss-refresh-extra.xml")

        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        bed.feedMock.handler = { _ in
            (extraData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = try await bed.service.refresh(podcastID: podcastID)

        #expect(outcome.notModified == false)
        #expect(outcome.newEpisodeCount == 1)
        #expect(outcome.totalEpisodeCount == 3)
    }

    @Test("refresh fires the new-episodes observer with the new GUIDs")
    func refreshFiresObserver() async throws {
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        let extraData = try fixtureData(named: "rss-refresh-extra.xml")

        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        let collector = ObserverCollector()
        await bed.service.setNewEpisodesObserver { id, guids in
            await collector.record(id: id, guids: guids)
        }

        bed.feedMock.handler = { _ in
            (extraData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await bed.service.refresh(podcastID: podcastID)

        let calls = await collector.calls
        #expect(calls.count == 1)
        #expect(calls.first?.id == podcastID)
        #expect(calls.first?.guids.count == 1)
    }

    @Test("refresh does not fire the observer when no new episodes appear")
    func refreshNoNewEpisodesSkipsObserver() async throws {
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        let collector = ObserverCollector()
        await bed.service.setNewEpisodesObserver { id, guids in
            await collector.record(id: id, guids: guids)
        }

        // Re-refresh the identical feed: every GUID already exists, so no new ones.
        _ = try await bed.service.refresh(podcastID: podcastID)

        let calls = await collector.calls
        #expect(calls.isEmpty)
    }

    // MARK: resumePosition

    @Test("resumePosition returns saved position when inProgress")
    func resumePositionInProgress() async throws {
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await bed.service.subscribe(feedURL: testFeedURL)

        let url = try await bed.service.audioURL(feedURL: testFeedURL, episodeGUID: ep1GUID)
        #expect(url.absoluteString == "https://example.com/ep1.mp3")
    }

    @Test("audioURL returns a local file URL when a downloaded state row has an existing file")
    func audioURLReturnsLocalFile() async throws {
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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

    // MARK: unsubscribe

    @Test("unsubscribe removes the podcast row and evicts the artwork directory")
    func unsubscribeRemovesRowAndEvicts() async throws {
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        // Artwork mock returns minimal image bytes.
        let artBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        bed.artMock.handler = { _ in
            (artBytes, HTTPURLResponse(
                url: URL(string: "https://example.com/artwork.jpg")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!)
        }
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        // Manually cache artwork so we have a directory to evict.
        let artURL = try #require(URL(string: "https://example.com/artwork.jpg"))
        let repo = PodcastRepository(database: bed.db)
        _ = await bed.artCache.cachePodcastArt(podcastID: podcastID, url: artURL, repo: repo)
        let artDir = bed.artTempDir.appendingPathComponent("\(podcastID)")
        #expect(FileManager.default.fileExists(atPath: artDir.path))

        // Write a downloaded episode file so unsubscribe must delete its directory.
        let dlTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(UUID().uuidString).tmp")
        try Data("audio".utf8).write(to: dlTemp)
        _ = try bed.downloadStore.moveIntoPlace(
            from: dlTemp, podcastID: podcastID, guid: ep1GUID, mime: "audio/mpeg"
        )
        let dlDir = bed.downloadRoot.appendingPathComponent("\(podcastID)")
        #expect(FileManager.default.fileExists(atPath: dlDir.path))

        try await bed.service.unsubscribe(podcastID: podcastID)

        // Row must be gone.
        do {
            _ = try await repo.fetch(id: podcastID)
            Issue.record("Expected podcast row to be deleted after unsubscribe")
        } catch {
            // Expected: notFound.
        }

        // Artwork directory and download directory must both be evicted.
        #expect(!FileManager.default.fileExists(atPath: artDir.path))
        #expect(!FileManager.default.fileExists(atPath: dlDir.path), "unsubscribe deletes the show's downloads")
    }

    // MARK: artwork cache

    @Test("artwork cache writes a file; second call does not re-download")
    func artworkCacheDeduplicatesDownloads() async throws {
        let bed = try await makeBed()

        // Set up an in-memory database with one podcast row.
        let db = bed.db
        let repo = PodcastRepository(database: db)
        let testPodcast = Podcast(
            feedURL: "https://example.com/feed.rss",
            title: "Test",
            explicit: false,
            subscribed: true,
            addedAt: fixedNow.timeIntervalSince1970
        )
        let podcastID = try await repo.insert(testPodcast)

        let artBytes = Data([0x89, 0x50, 0x4E, 0x47])
        var downloadCount = 0
        bed.artMock.handler = { _ in
            downloadCount += 1
            return (artBytes, HTTPURLResponse(
                url: URL(string: "https://cdn.example.com/art.png")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!)
        }

        let artURL = try #require(URL(string: "https://cdn.example.com/art.png"))

        // First call should download and write.
        let path1 = await bed.artCache.cachePodcastArt(podcastID: podcastID, url: artURL, repo: repo)
        #expect(path1 != nil)
        #expect(try FileManager.default.fileExists(atPath: #require(path1)))

        // Second call should skip the download.
        let path2 = await bed.artCache.cachePodcastArt(podcastID: podcastID, url: artURL, repo: repo)
        #expect(path2 == path1)
        #expect(downloadCount == 1)

        // Path must be written into the podcasts row.
        let fetched = try await repo.fetch(id: podcastID)
        #expect(fetched.artworkPath == path1)

        // Cleanup.
        try? FileManager.default.removeItem(at: bed.artTempDir)
    }

    @Test("refresh re-caches cover art when the cached file is missing")
    func refreshSelfHealsMissingArtwork() async throws {
        let bed = try await makeBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        let artBytes = Data([0x89, 0x50, 0x4E, 0x47])
        bed.artMock.handler = { _ in
            (artBytes, HTTPURLResponse(
                url: URL(string: "https://example.com/artwork.jpg")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }
        bed.feedMock.handler = { _ in
            (rssData, HTTPURLResponse(url: testFeedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        // subscribe caches art on a detached task; wait for the file + path to land.
        let repo = PodcastRepository(database: bed.db)
        let cachedPath = try #require(await pollArtworkPath(repo: repo, id: podcastID))
        #expect(FileManager.default.fileExists(atPath: cachedPath))

        // Simulate the overnight wipe: delete the cached file (the row path stays).
        try FileManager.default.removeItem(atPath: cachedPath)
        #expect(!FileManager.default.fileExists(atPath: cachedPath))

        // A refresh must re-download the missing art and preserve the path.
        _ = try await bed.service.refresh(podcastID: podcastID)
        #expect(try await pollFileExists(cachedPath), "missing cover art should self-heal on refresh")
        let healed = try await repo.fetch(id: podcastID)
        #expect(healed.artworkPath == cachedPath)

        try? FileManager.default.removeItem(at: bed.artTempDir)
    }

    @Test("artwork cache rejects art larger than its byte cap, accepts within it")
    func artworkCacheHonoursByteCap() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("artcap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockHTTPClient()
        let cache = PodcastArtworkCache(http: mock, root: tempRoot, maxBytes: 8)
        let url = try #require(URL(string: "https://cdn.example.com/big.png"))

        let db = try await Database(location: .inMemory)
        let podcastRepo = PodcastRepository(database: db)

        // 9 bytes > cap of 8: rejected, no file written.
        mock.handler = { _ in
            (Data(count: 9), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let id = try await podcastRepo.insert(Podcast(
            feedURL: "https://example.com/feed.rss", title: "T", addedAt: 0
        ))
        let tooBig = await cache.cachePodcastArt(podcastID: id, url: url, repo: podcastRepo)
        #expect(tooBig == nil, "art over the cap must be rejected")

        // 8 bytes == cap: accepted and written.
        mock.handler = { _ in
            (Data(count: 8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let okPath = await cache.cachePodcastArt(podcastID: id, url: url, repo: podcastRepo)
        #expect(okPath != nil, "art within the cap must be accepted")
    }
}
