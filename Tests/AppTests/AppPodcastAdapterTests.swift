import AudioEngine
import Foundation
import Persistence
import Playback
import Podcasts
import Testing
import UI

// MARK: - Test bed

/// `Podcasts.HTTPClient` stub: serves one canned feed, 404 for everything else.
private final class StubHTTP: HTTPClient, @unchecked Sendable {
    var feedData = Data()
    var feedURL: URL?
    private(set) var requested: [URL] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        self.requested.append(url)
        let hit = url == self.feedURL
        let response = HTTPURLResponse(url: url, statusCode: hit ? 200 : 404, httpVersion: nil, headerFields: nil)!
        return (hit ? self.feedData : Data(), response)
    }
}

private let feedURL = URL(string: "https://example.test/feed.rss")!

private let feedXML = """
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0">
<channel>
  <title>Seam Show</title>
  <itunes:author>Seam Author</itunes:author>
  <description>A show for adapter tests.</description>
  <itunes:image href="https://example.test/art.jpg"/>
  <podcast:person role="host">Host One</podcast:person>
  <item>
    <title>Episode One</title>
    <guid isPermaLink="false">seam-ep1</guid>
    <pubDate>Mon, 10 Jun 2024 10:00:00 +0000</pubDate>
    <enclosure url="https://example.test/ep1.mp3" type="audio/mpeg" length="111"/>
    <itunes:duration>600</itunes:duration>
  </item>
</channel>
</rss>
"""

private struct Bed {
    let db: Database
    let service: PodcastService
    let http: StubHTTP
    let player: QueuePlayer
}

private func makeBed() async throws -> Bed {
    let db = try await Database(location: .inMemory)
    let http = StubHTTP()
    http.feedURL = feedURL
    http.feedData = Data(feedXML.utf8)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("app-adapter-\(UUID().uuidString)", isDirectory: true)
    let service = PodcastService(
        podcastRepo: PodcastRepository(database: db),
        episodeRepo: EpisodeRepository(database: db),
        stateRepo: EpisodeStateRepository(database: db),
        transcriptRepo: TranscriptRepository(database: db),
        fetcher: FeedFetcher(http: http),
        artwork: PodcastArtworkCache(http: http, root: tmp.appendingPathComponent("art")),
        downloadStore: DownloadStore(root: tmp.appendingPathComponent("dl")),
        transcriptHTTP: http,
        now: { Date(timeIntervalSince1970: 1_720_000_000) }
    )
    let player = QueuePlayer(engine: AudioEngine(), database: db)
    return Bed(db: db, service: service, http: http, player: player)
}

// MARK: - AppPodcastActions

@Suite("AppPodcastActions seam (#422)")
struct AppPodcastActionsTests {
    @Test("subscribe carries the directory ids through to the row")
    func subscribeCarriesIDs() async throws {
        let bed = try await makeBed()
        let actions = AppPodcastActions(service: bed.service, player: bed.player, downloads: nil)
        let id = try await actions.subscribe(feedURL: feedURL, podcastIndexID: 42, itunesCollectionID: 9999)
        let row = try await PodcastRepository(database: bed.db).fetch(id: id)
        #expect(row.title == "Seam Show")
        #expect(row.podcastIndexID == 42)
        #expect(row.itunesCollectionID == 9999)
    }

    @Test("per-show settings and auto-download reach their columns")
    func perShowSettings() async throws {
        let bed = try await makeBed()
        let actions = AppPodcastActions(service: bed.service, player: bed.player, downloads: nil)
        let id = try await actions.subscribe(feedURL: feedURL)
        try await actions.setPlaybackSpeed(1.5, podcastID: id)
        try await actions.setEpisodeSort("oldest", podcastID: id)
        try await actions.setRetentionLimit(7, podcastID: id)
        try await actions.setAutoDownload(true, podcastID: id)
        let row = try await PodcastRepository(database: bed.db).fetch(id: id)
        #expect(row.playbackSpeed == 1.5)
        #expect(row.episodeSort == "oldest")
        #expect(row.retentionLimit == 7)
        #expect(row.autoDownload == true)
    }

    @Test("markPlayed, markUnplayed and markAllPlayed reach the episode state")
    func playState() async throws {
        let bed = try await makeBed()
        let actions = AppPodcastActions(service: bed.service, player: bed.player, downloads: nil)
        let id = try await actions.subscribe(feedURL: feedURL)
        let state = EpisodeStateRepository(database: bed.db)
        await actions.markPlayed(podcastID: id, guid: "seam-ep1")
        #expect(try await state.fetch(podcastID: id, guid: "seam-ep1")?.playState == .played)
        await actions.markUnplayed(podcastID: id, guid: "seam-ep1")
        #expect(try await state.fetch(podcastID: id, guid: "seam-ep1")?.playState == .unplayed)
        await actions.markAllPlayed(podcastID: id)
        #expect(try await state.fetch(podcastID: id, guid: "seam-ep1")?.playState == .played)
    }

    @Test("exportOPML includes the subscribed feed and unsubscribe removes it")
    func opmlAndUnsubscribe() async throws {
        let bed = try await makeBed()
        let actions = AppPodcastActions(service: bed.service, player: bed.player, downloads: nil)
        let id = try await actions.subscribe(feedURL: feedURL)
        let opml = try await String(decoding: actions.exportOPML(), as: UTF8.self)
        #expect(opml.contains("example.test/feed.rss"))
        try await actions.unsubscribe(podcastID: id)
        #expect(try await PodcastRepository(database: bed.db).fetchByFeedURL(feedURL.absoluteString) == nil)
    }

    @Test("play builds a podcast queue item with the episode and show identity")
    func playEnqueues() async throws {
        let bed = try await makeBed()
        let actions = AppPodcastActions(service: bed.service, player: bed.player, downloads: nil)
        let id = try await actions.subscribe(feedURL: feedURL)
        let podcast = try await PodcastRepository(database: bed.db).fetch(id: id)
        let episode = try #require(try await bed.service.episodes(podcastID: id).first)
        await actions.play(episode: episode, podcast: podcast)
        // Loading fails (no resolver, no audio), but the queue already holds the item.
        let current = await bed.player.queue.currentItem
        #expect(current?.title == "Episode One")
        #expect(current?.artistName == "Seam Show")
        #expect(current?.playableSource == .podcast(feedURL: feedURL, episodeGUID: "seam-ep1"))
    }
}

// MARK: - AppPodcastSearch

@Suite("AppPodcastSearch seam (#422)")
struct AppPodcastSearchTests {
    @Test("detail carries the hint's directory ids, the parsed persons, and subscription status")
    func detailCarriesEverything() async throws {
        let bed = try await makeBed()
        let search = AppPodcastSearch(
            searchService: PodcastSearchService(podcastIndex: nil, itunes: ITunesSearchClient(http: bed.http)),
            fetcher: FeedFetcher(http: bed.http),
            parser: FeedParser(),
            podcastRepo: PodcastRepository(database: bed.db)
        )
        let hint = UIPodcastSearchResult(
            canonicalFeedKey: "example.test/feed.rss",
            feedURL: feedURL,
            title: "Seam Show",
            podcastIndexID: 42,
            itunesCollectionID: 9999
        )

        var detail = try await search.detail(feedURL: feedURL, hint: hint)
        #expect(detail.title == "Seam Show")
        #expect(detail.author == "Seam Author")
        #expect(detail.podcastIndexID == 42)
        #expect(detail.itunesCollectionID == 9999)
        #expect(detail.persons.map(\.name) == ["Host One"])
        #expect(detail.episodePreview.map(\.guid) == ["seam-ep1"])
        #expect(detail.alreadySubscribed == false)
        #expect(detail.podcastID == nil)

        let id = try await bed.service.subscribe(feedURL: feedURL)
        detail = try await search.detail(feedURL: feedURL, hint: nil)
        #expect(detail.alreadySubscribed)
        #expect(detail.podcastID == id)
    }
}

// MARK: - AppPodcastResolver

@Suite("AppPodcastResolver seam (#422)")
struct AppPodcastResolverTests {
    @Test("audioURL resolves the enclosure and markPlayed reaches the state row")
    func resolverForwards() async throws {
        let bed = try await makeBed()
        let id = try await bed.service.subscribe(feedURL: feedURL)
        let resolver = AppPodcastResolver(service: bed.service)
        #expect(try await resolver.audioURL(feedURL: feedURL, episodeGUID: "seam-ep1").absoluteString == "https://example.test/ep1.mp3")
        #expect(await resolver.resumePosition(feedURL: feedURL, episodeGUID: "seam-ep1") == 0)
        await resolver.persistPosition(feedURL: feedURL, episodeGUID: "seam-ep1", position: 120, duration: 600)
        #expect(await resolver.resumePosition(feedURL: feedURL, episodeGUID: "seam-ep1") == 120)
        await resolver.markPlayed(feedURL: feedURL, episodeGUID: "seam-ep1")
        #expect(try await EpisodeStateRepository(database: bed.db).fetch(podcastID: id, guid: "seam-ep1")?.playState == .played)
    }
}
