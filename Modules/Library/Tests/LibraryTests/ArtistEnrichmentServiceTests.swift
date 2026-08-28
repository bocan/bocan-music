import Acoustics
import Foundation
import Persistence
import Testing
@testable import Library

/// Serves a canned MusicBrainz artist per MBID; anything else is a 404, and a
/// configurable MBID answers 503 to simulate the rate limit.
private final class ArtistStubHTTP: HTTPClient, @unchecked Sendable {
    var artists: [String: (name: String, sortName: String, disambiguation: String)] = [:]
    /// MBIDs that answer 503; each hit decrements `rateLimitHits`, and the
    /// limit lifts when it reaches zero (nil = limited forever).
    var rateLimited: Set<String> = []
    var rateLimitHits: Int?
    private(set) var requests = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requests += 1
        let url = request.url!
        let mbid = url.lastPathComponent
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        if self.rateLimited.contains(mbid) {
            if let hits = self.rateLimitHits {
                self.rateLimitHits = hits - 1
                if hits <= 0 { self.rateLimited.remove(mbid) } else { return (Data(), response(503)) }
            } else {
                return (Data(), response(503))
            }
        }
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
            pacing: .zero, backoff: .milliseconds(1), maxBackoffs: 3,
            now: { Date(timeIntervalSince1970: 1_720_000_000) }
        )
    }

    @Test("a pass fills disambiguation, a missing sort name, and stamps fetched_at once")
    func passEnriches() async throws {
        let db = try await Database(location: .inMemory)
        let repo = ArtistRepository(database: db)
        _ = try await repo.findOrCreate(name: "John Williams", musicbrainzID: "mb-jw")
        _ = try await repo.findOrCreate(name: "The Kestrels", sortName: "Kestrels, The", musicbrainzID: "mb-k")
        _ = try await repo.findOrCreate(name: "John Williams feat. Yo-Yo Ma", musicbrainzID: "mb-jw")
        _ = try await repo.findOrCreate(name: "Untagged")
        let http = ArtistStubHTTP()
        http.artists["mb-jw"] = ("John Williams", "Williams, John", "film composer")
        http.artists["mb-k"] = ("The Kestrels", "Kestrels, The", "")
        let service = self.makeService(db, http: http)

        #expect(await service.enrichOnce() == 2, "two MBIDs, two lookups, three rows stamped")
        #expect(http.requests == 2, "the feat. variant shares its MBID and costs no request")
        #expect(try await repo.fetchOne(name: "John Williams feat. Yo-Yo Ma")?.disambiguation == "film composer")
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

    @Test("siblings sharing an MBID inside one batch cost no extra request")
    func siblingsInOneBatch() async throws {
        let db = try await Database(location: .inMemory)
        let repo = ArtistRepository(database: db)
        for name in ["Santana", "Santana feat. Rob Thomas", "Santana feat. Everlast", "Santana & Michelle Branch"] {
            _ = try await repo.findOrCreate(name: name, musicbrainzID: "mb-santana")
        }
        let http = ArtistStubHTTP()
        http.artists["mb-santana"] = ("Santana", "Santana", "US Latin rock band")
        let client = MusicBrainzClient(
            userAgent: "Bocan/test ( https://bocan.app )",
            rateLimiter: RateLimiter(maxRequests: 1000, per: 1.0),
            httpClient: http
        )
        // Batch size larger than the family, so all four rows arrive together.
        let service = ArtistEnrichmentService(
            artists: repo, client: client, batchSize: 10, pacing: .zero, backoff: .milliseconds(1), maxBackoffs: 1
        )
        #expect(await service.enrichOnce() == 1)
        #expect(http.requests == 1)
        #expect(try await repo.countNeedingEnrichment() == 0)
    }

    @Test("a transient 503 is retried after a backoff and the pass carries on")
    func transientRateLimitRetried() async throws {
        let db = try await Database(location: .inMemory)
        let repo = ArtistRepository(database: db)
        _ = try await repo.findOrCreate(name: "Limited", musicbrainzID: "mb-limited")
        _ = try await repo.findOrCreate(name: "Later", musicbrainzID: "mb-later")
        let http = ArtistStubHTTP()
        http.rateLimited = ["mb-limited"]
        http.rateLimitHits = 2
        http.artists["mb-limited"] = ("Limited", "Limited", "after backoff")
        http.artists["mb-later"] = ("Later", "Later", "x")
        #expect(await self.makeService(db, http: http).enrichOnce() == 2)
        #expect(try await repo.fetchOne(name: "Limited")?.disambiguation == "after backoff")
        #expect(try await repo.fetchOne(name: "Later")?.disambiguation == "x")
    }

    @Test("a 404 stamps the row so a stale MBID is not retried; a persistent 503 pauses the pass unstamped")
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
