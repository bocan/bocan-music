import Acoustics
import Foundation
import Persistence
import Testing
@testable import Library

/// Serves a canned MusicBrainz artist per MBID; anything else is a 404, and a
/// configurable MBID answers 503 to simulate the rate limit.
private final class ArtistStubHTTP: HTTPClient, @unchecked Sendable {
    var artists: [String: (name: String, sortName: String, disambiguation: String)] = [:]
    var rateLimited: Set<String> = []
    private(set) var requests = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requests += 1
        let url = request.url!
        let mbid = url.lastPathComponent
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        if self.rateLimited.contains(mbid) { return (Data(), response(503)) }
        guard let artist = self.artists[mbid] else { return (Data(), response(404)) }
        let json: [String: Any] = [
            "id": mbid, "name": artist.name, "sort-name": artist.sortName,
            "disambiguation": artist.disambiguation, "type": "Group", "relations": [],
        ]
        return try (JSONSerialization.data(withJSONObject: json), response(200))
    }
}

@Suite("ArtistEnrichmentService (#401)")
struct ArtistEnrichmentServiceTests {
    private func makeService(_ db: Database, http: ArtistStubHTTP) -> ArtistEnrichmentService {
        let client = MusicBrainzClient(
            userAgent: "Bocan/test ( https://bocan.app )",
            rateLimiter: RateLimiter(maxRequests: 1000, per: 1.0),
            httpClient: http
        )
        return ArtistEnrichmentService(
            artists: ArtistRepository(database: db), client: client, batchSize: 2,
            now: { Date(timeIntervalSince1970: 1_720_000_000) }
        )
    }

    @Test("a pass fills disambiguation, a missing sort name, and stamps fetched_at once")
    func passEnriches() async throws {
        let db = try await Database(location: .inMemory)
        let repo = ArtistRepository(database: db)
        _ = try await repo.findOrCreate(name: "John Williams", musicbrainzID: "mb-jw")
        _ = try await repo.findOrCreate(name: "The Kestrels", sortName: "Kestrels, The", musicbrainzID: "mb-k")
        _ = try await repo.findOrCreate(name: "Untagged")
        let http = ArtistStubHTTP()
        http.artists["mb-jw"] = ("John Williams", "Williams, John", "film composer")
        http.artists["mb-k"] = ("The Kestrels", "Kestrels, The", "")
        let service = self.makeService(db, http: http)

        #expect(await service.enrichOnce() == 2)
        let williams = try #require(try await repo.fetchOne(name: "John Williams"))
        #expect(williams.disambiguation == "film composer")
        #expect(williams.sortName == "Williams, John", "MusicBrainz fills the missing sort name")
        #expect(williams.musicbrainzFetchedAt == 1_720_000_000)
        let kestrels = try #require(try await repo.fetchOne(name: "The Kestrels"))
        #expect(kestrels.disambiguation == nil, "empty disambiguation is NULL")
        #expect(kestrels.sortName == "Kestrels, The")
        #expect(try await repo.fetchOne(name: "Untagged")?.musicbrainzFetchedAt == nil, "no MBID, never looked up")

        // Second pass has nothing to do and makes no requests.
        let before = http.requests
        #expect(await service.enrichOnce() == 0)
        #expect(http.requests == before)
    }

    @Test("a 404 stamps the row so a stale MBID is not retried; a 503 pauses the pass unstamped")
    func errorsHandled() async throws {
        let db = try await Database(location: .inMemory)
        let repo = ArtistRepository(database: db)
        let stale = try await repo.findOrCreate(name: "Stale", musicbrainzID: "mb-gone")
        _ = try await repo.findOrCreate(name: "Limited", musicbrainzID: "mb-limited")
        _ = try await repo.findOrCreate(name: "Later", musicbrainzID: "mb-later")
        let http = ArtistStubHTTP()
        http.rateLimited = ["mb-limited"]
        http.artists["mb-later"] = ("Later", "Later", "x")
        let service = self.makeService(db, http: http)

        #expect(await service.enrichOnce() == 0)
        #expect(try await repo.fetch(id: #require(stale.id)).musicbrainzFetchedAt != nil, "404 stamped")
        #expect(try await repo.fetch(id: #require(stale.id)).disambiguation == nil)
        #expect(try await repo.fetchOne(name: "Limited")?.musicbrainzFetchedAt == nil, "503 leaves the row for next time")
        #expect(try await repo.fetchOne(name: "Later")?.musicbrainzFetchedAt == nil, "pass paused before reaching it")

        http.rateLimited = []
        http.artists["mb-limited"] = ("Limited", "Limited", "ok now")
        #expect(await service.enrichOnce() == 2)
        #expect(try await repo.fetchOne(name: "Limited")?.disambiguation == "ok now")
    }

    @Test("enrich(artistID:) refreshes one artist on demand")
    func onDemand() async throws {
        let db = try await Database(location: .inMemory)
        let repo = ArtistRepository(database: db)
        let artist = try await repo.findOrCreate(name: "Solo", musicbrainzID: "mb-solo")
        let http = ArtistStubHTTP()
        http.artists["mb-solo"] = ("Solo", "Solo", "singer")
        let refreshed = try await self.makeService(db, http: http).enrich(artistID: #require(artist.id))
        #expect(refreshed.disambiguation == "singer")
    }
}
