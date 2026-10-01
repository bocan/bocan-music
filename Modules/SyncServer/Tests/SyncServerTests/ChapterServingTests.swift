import Foundation
import Persistence
import Podcasts
import Testing
@testable import SyncServer

/// Records every request `URLSession.shared` would make to the chapters host
/// and fails it, so a handler that reached for the network is both caught and
/// kept off it.
private final class OutboundRequestTrap: URLProtocol, @unchecked Sendable {
    static let host = "chapters.invalid"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _count = 0

    static var count: Int {
        self.lock.withLock { self._count }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard request.url?.host == self.host else { return false }
        self.lock.withLock { self._count += 1 }
        return true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        self.client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

@Suite("ChapterServing", .serialized)
struct ChapterServingTests {
    private static let chaptersURL = "https://\(OutboundRequestTrap.host)/ep1/chapters.json"
    private static let guid = "https://x.test/ep/1"

    private func context(trusted: Bool) -> ConnectionContext {
        let context = ConnectionContext()
        if trusted {
            context.recordPeer(certificateDER: Data([0x01]), fingerprint: "aa", isPairing: false, isTrusted: true)
        }
        return context
    }

    private func get(_ database: Database, _ path: String, trusted: Bool = true) async -> HttpResponse {
        await Router(routes: FileServing(database: database).routes()).dispatch(
            HttpRequest(method: "GET", path: path, query: [:], headers: [:], body: Data()),
            context: self.context(trusted: trusted)
        )
    }

    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "chapters-pc20", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// One show with one downloaded episode that has a chapters URL. Returns
    /// the podcast id; the wire episode id is `FileServing.guidHash(Self.guid)`.
    private func seedDownloadedEpisode(_ database: Database, downloaded: Bool = true) async throws -> Int64 {
        let podcastId = try await PodcastRepository(database: database).insert(
            Podcast(feedURL: "https://x.test/feed", title: "Show", addedAt: 0)
        )
        _ = try await EpisodeRepository(database: database).upsert(PodcastEpisode(
            podcastID: podcastId,
            guid: Self.guid,
            title: "E1",
            audioURL: "https://x.test/ep1.mp3",
            audioMIME: "audio/mpeg",
            chaptersURL: Self.chaptersURL,
            addedAt: 0
        ))
        if downloaded {
            try await EpisodeStateRepository(database: database).setDownloadState(
                podcastID: podcastId, guid: Self.guid, state: .downloaded, path: "/tmp/ep1.mp3", bytes: 1, hash: "h"
            )
        }
        return podcastId
    }

    private func cache(_ database: Database, podcastId: Int64, body: Data, sourceURL: String = chaptersURL) async throws {
        try await ChaptersRepository(database: database).upsert(PodcastChapters(
            podcastID: podcastId,
            guid: Self.guid,
            content: #require(String(data: body, encoding: .utf8)),
            sourceURL: sourceURL
        ))
    }

    private var path: String {
        "/v1/chapters/\(FileServing.guidHash(Self.guid))"
    }

    @Test("a paired device is served the cached document byte for byte")
    func servesCachedDocument() async throws {
        let database = try await Database(location: .inMemory)
        let podcastId = try await seedDownloadedEpisode(database)
        let body = try fixture()
        try await self.cache(database, podcastId: podcastId, body: body)

        let response = await self.get(database, self.path)
        #expect(response.status == 200)
        #expect(response.headers["content-type"] == "application/json")
        #expect(response.body == body)
        // The phone parses it with the same rules the Mac does.
        #expect(ChaptersFetcher.parse(response.body).map(\.title) == ["Intro", "Sponsor", "Main Topic"])
    }

    @Test("an unpaired connection is refused before the cache is read")
    func unpairedIsRefused() async throws {
        let database = try await Database(location: .inMemory)
        let podcastId = try await seedDownloadedEpisode(database)
        try await self.cache(database, podcastId: podcastId, body: self.fixture())

        #expect(await self.get(database, self.path, trusted: false).status == 403)
    }

    @Test("nothing cached is a 404, and the handler makes no outbound request")
    func notCachedIs404WithoutNetwork() async throws {
        URLProtocol.registerClass(OutboundRequestTrap.self)
        defer { URLProtocol.unregisterClass(OutboundRequestTrap.self) }
        let before = OutboundRequestTrap.count

        let database = try await Database(location: .inMemory)
        _ = try await self.seedDownloadedEpisode(database)

        #expect(await self.get(database, self.path).status == 404)
        #expect(await self.get(database, "/v1/chapters/unknown").status == 404)
        #expect(OutboundRequestTrap.count == before, "the chapters URL must never be fetched from a serving handler")
    }

    @Test("a document from a chapters URL the feed has since changed is not served")
    func staleDocumentIs404() async throws {
        let database = try await Database(location: .inMemory)
        let podcastId = try await seedDownloadedEpisode(database)
        try await self.cache(database, podcastId: podcastId, body: self.fixture(), sourceURL: "https://x.test/old.json")

        #expect(await self.get(database, self.path).status == 404)
    }

    @Test("an episode the manifest does not list is a 404 even with a cached document")
    func outsideTheSyncSetIs404() async throws {
        // Not downloaded: the manifest lists downloaded episodes only.
        let database = try await Database(location: .inMemory)
        let podcastId = try await seedDownloadedEpisode(database, downloaded: false)
        try await self.cache(database, podcastId: podcastId, body: self.fixture())
        #expect(await self.get(database, self.path).status == 404)

        // Downloaded, but the profile leaves podcasts out.
        let excluded = try await Database(location: .inMemory)
        let excludedId = try await seedDownloadedEpisode(excluded)
        try await self.cache(excluded, podcastId: excludedId, body: self.fixture())
        try await SyncProfileRepository(database: excluded).setProfileJSON(
            SyncProfileDocument(profile: .everything(includePodcasts: false)).encoded()
        )
        #expect(await self.get(excluded, self.path).status == 404)
    }
}
