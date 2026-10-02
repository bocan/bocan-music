import Foundation
import Persistence
import Testing
@testable import Podcasts

// MARK: - Helpers

// The shared `TestBed`, `makePodcastServiceBed` and fixtures live in
// `PodcastServiceTestSupport.swift`.

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
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        let refreshData = try fixtureData(named: "rss-refresh-extra.xml")

        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
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
            try (refreshData, stubResponse(url: testFeedURL))
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
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        var requestCount = 0
        let body = "WEBVTT\n\n00:00.000 --> 00:01.000\nHello"
        bed.transcriptMock.handler = { _ in
            requestCount += 1
            return try (
                Data(body.utf8),
                stubResponse("https://example.com/ep1-transcript.vtt", headers: ["Content-Type": "text/vtt"])
            )
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
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }

        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)
        #expect(podcastID > 0)

        let repo = PodcastRepository(database: bed.db)
        let podcast = try await repo.fetch(id: podcastID)
        #expect(podcast.title == "Full Feature Podcast")

        let epRepo = EpisodeRepository(database: bed.db)
        let episodes = try await epRepo.fetchForPodcast(podcastID: podcastID)
        #expect(episodes.count == 2)
    }

    @Test("re-subscribing the same feed upserts and does not duplicate rows")
    func reSubscribeIsIdempotent() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
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

    // MARK: Stored scheme (#487)

    @Test("a feed that only answers over http on the local network is stored as http and refreshes (#487)")
    func lanHTTPFeedStoredAsHTTP() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        let lan = try #require(URL(string: "http://192.168.1.10:8000/feed.xml"))
        bed.feedMock.handler = { request in
            if request.url?.scheme == "https" {
                throw URLError(.secureConnectionFailed)
            }
            return try (rssData, stubResponse(url: lan))
        }

        let podcastID = try await bed.service.subscribe(feedURL: lan)
        let stored = try await PodcastRepository(database: bed.db).fetch(id: podcastID)
        #expect(stored.feedURL == "http://192.168.1.10:8000/feed.xml")

        let outcome = try await bed.service.refresh(podcastID: podcastID)
        #expect(outcome.notModified == false, "the stored address must still answer")
    }

    @Test("a plain-http listing whose https twin works is stored as https, one subscription under either scheme (#487)")
    func httpListingWithTwinStoredAsHTTPS() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { request in
            let url = request.url ?? testFeedURL
            return try (rssData, stubResponse(url: url))
        }
        let listed = try #require(URL(string: "http://example.com/feed.rss"))

        let id1 = try await bed.service.subscribe(feedURL: listed)
        let id2 = try await bed.service.subscribe(feedURL: testFeedURL)
        let id3 = try await bed.service.subscribe(feedURL: listed)
        #expect(id1 == id2)
        #expect(id2 == id3)
        let all = try await PodcastRepository(database: bed.db).fetchAllSubscribed()
        #expect(all.map(\.feedURL) == ["https://example.com/feed.rss"])
    }

    @Test("a subscription stored as https that only answers over http moves to http when re-added, keeping its row (#487)")
    func reAddAdoptsWorkingScheme() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        let repo = PodcastRepository(database: bed.db)
        // What the pre-#487 normaliser stored for a feed on the local network.
        let legacyID = try await repo.insert(Podcast(
            feedURL: "https://192.168.1.10:8000/feed.xml",
            title: "Home Server Show",
            author: nil,
            addedAt: fixedNow.timeIntervalSince1970
        ))
        try await bed.service.setPlaybackSpeed(1.5, podcastID: legacyID)
        let lan = try #require(URL(string: "http://192.168.1.10:8000/feed.xml"))
        bed.feedMock.handler = { request in
            if request.url?.scheme == "https" {
                throw URLError(.secureConnectionFailed)
            }
            return try (rssData, stubResponse(url: lan))
        }

        let id = try await bed.service.subscribe(feedURL: lan)
        #expect(id == legacyID)
        #expect(try await repo.fetchAllSubscribed().count == 1)
        let moved = try await repo.fetch(id: id)
        #expect(moved.feedURL == "http://192.168.1.10:8000/feed.xml")
        #expect(moved.playbackSpeed == 1.5, "user settings stay with the row")
        let audio = try await bed.service.audioURL(feedURL: lan, episodeGUID: ep1GUID)
        #expect(!audio.absoluteString.isEmpty, "playback resolves the show by its new address")
    }

    @Test("directory IDs survive a refresh and the plain-ID subscribe overload stores them (#409)")
    func directoryIDsSurviveRefresh() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }
        let podcastID = try await bed.service.subscribe(
            feedURL: testFeedURL, podcastIndexID: 42, itunesCollectionID: 9999
        )
        let repo = PodcastRepository(database: bed.db)
        #expect(try await repo.fetch(id: podcastID).podcastIndexID == 42)

        _ = try await bed.service.refresh(podcastID: podcastID)
        let after = try await repo.fetch(id: podcastID)
        #expect(after.podcastIndexID == 42)
        #expect(after.itunesCollectionID == 9999)
    }

    @Test("index hints land in itunes_collection_id and podcast_index_id")
    func indexHintsStored() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
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
        let bed = try await makePodcastServiceBed()
        let badURL = try #require(URL(string: "ftp://example.com/feed"))
        await #expect(throws: PodcastsError.self) {
            _ = try await bed.service.subscribe(feedURL: badURL)
        }
    }

    // MARK: refresh - 304

    @Test("refresh on 304 stamps last_refreshed_at and leaves episodes untouched")
    func refresh304() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }

        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        // Second call returns 304.
        let refETag = "\"abc123\""
        bed.feedMock.handler = { _ in
            try (Data(), stubResponse(url: testFeedURL, status: 304, headers: ["ETag": refETag]))
        }

        let t1 = fixedNow.addingTimeInterval(60)
        var t1Bed = bed
        _ = t1Bed // silence unused warning
        // Use a fresh service with a later `now` to detect the timestamp update.
        let lateBed = try await makePodcastServiceBed(nowDate: fixedNow.addingTimeInterval(60))
        let rssData2 = try fixtureData(named: "rss-full.xml")
        lateBed.feedMock.handler = { _ in
            try (rssData2, stubResponse(url: testFeedURL))
        }
        let lateID = try await lateBed.service.subscribe(feedURL: testFeedURL)

        lateBed.feedMock.handler = { _ in
            try (Data(), stubResponse(url: testFeedURL, status: 304))
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

    @Test("subscribe stores item-level podcast:person credits on the episode row (#411)")
    func subscribeStoresEpisodePersons() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-podcast-namespace.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        let episodes = try await EpisodeRepository(database: bed.db).fetchForPodcast(podcastID: podcastID)
        let ep1 = try #require(episodes.first { $0.guid == "guid-ep1" })
        #expect(ep1.persons.map(\.name) == ["Alice Brown"])
        #expect(ep1.persons.first?.role == "guest")
        #expect(ep1.persons.first?.imageURL == "https://example.com/alice.jpg")

        // An item with no podcast:person keeps NULL so the UI falls back to the show's hosts.
        let ep2 = try #require(episodes.first { $0.guid == "guid-ep2" })
        #expect(ep2.personsJSON == nil)
        #expect(ep2.persons.isEmpty)
    }

    @Test("refresh with extra episode produces newEpisodeCount == 1")
    func refreshNewEpisode() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        let extraData = try fixtureData(named: "rss-refresh-extra.xml")

        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        bed.feedMock.handler = { _ in
            try (extraData, stubResponse(url: testFeedURL))
        }
        let outcome = try await bed.service.refresh(podcastID: podcastID)

        #expect(outcome.notModified == false)
        #expect(outcome.newEpisodeCount == 1)
        #expect(outcome.totalEpisodeCount == 3)
    }

    @Test("refresh fires the new-episodes observer with the new GUIDs")
    func refreshFiresObserver() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        let extraData = try fixtureData(named: "rss-refresh-extra.xml")

        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        let collector = ObserverCollector()
        await bed.service.setNewEpisodesObserver { id, guids in
            await collector.record(id: id, guids: guids)
        }

        bed.feedMock.handler = { _ in
            try (extraData, stubResponse(url: testFeedURL))
        }
        _ = try await bed.service.refresh(podcastID: podcastID)

        let calls = await collector.calls
        #expect(calls.count == 1)
        #expect(calls.first?.id == podcastID)
        #expect(calls.first?.guids.count == 1)
    }

    @Test("refresh does not fire the observer when no new episodes appear")
    func refreshNoNewEpisodesSkipsObserver() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
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
}
