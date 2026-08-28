import Foundation
import Testing
@testable import Acoustics

@Suite("MusicBrainzClient entities (#412)")
struct MusicBrainzEntityTests {
    private func makeClient(_ mock: MockHTTPClient) -> MusicBrainzClient {
        MusicBrainzClient(
            userAgent: "Bocan/test ( https://bocan.app )",
            rateLimiter: RateLimiter(maxRequests: 100, per: 1.0),
            httpClient: mock
        )
    }

    @Test("searchReleaseGroups decodes the search shape and builds the query")
    func releaseGroupSearch() async throws {
        let mock = MockHTTPClient()
        mock.responseData = Bundle.fixtureData(named: "Fixtures/mb_release_group_search.json")
        let groups = try await self.makeClient(mock).searchReleaseGroups(artist: "The Beatles", album: "Abbey Road")
        #expect(groups.count == 2)
        #expect(groups.first?.title == "Abbey Road")
        #expect(groups.first?.artistName == "The Beatles")
        #expect(groups.first?.year == 1969)
        #expect(groups.first?.primaryType == "Album")
        #expect(groups.last?.secondaryTypes == ["Compilation"])
        let url = try #require(mock.lastRequest?.url?.absoluteString.removingPercentEncoding)
        #expect(url.contains("/ws/2/release-group?"))
        #expect(url.contains("query=artist:\"The Beatles\" AND releasegroup:\"Abbey Road\""))
        #expect(url.hasSuffix("fmt=json"))
        #expect(mock.lastRequest?.value(forHTTPHeaderField: "User-Agent") == "Bocan/test ( https://bocan.app )")
    }

    @Test("fetchArtist decodes life span, members with dates, and links")
    func artistLookup() async throws {
        let mock = MockHTTPClient()
        mock.responseData = Bundle.fixtureData(named: "Fixtures/mb_artist_lookup.json")
        let artist = try await self.makeClient(mock).fetchArtist(mbid: "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d")
        #expect(artist.name == "The Beatles")
        #expect(artist.sortName == "Beatles, The")
        #expect(artist.type == "Group")
        #expect(artist.country == "GB")
        #expect(artist.lifeSpan?.begin == "1957-03")
        #expect(artist.lifeSpan?.ended == true)
        let members = artist.members
        #expect(members.count == 5)
        #expect(members.map(\.artist.name) == ["John Lennon", "George Harrison", "Paul McCartney", "Pete Best", "Ringo Starr"])
        #expect(members.first { $0.artist.name == "Pete Best" }?.end == "1962-08")
        #expect(members.first { $0.artist.name == "Paul McCartney" }?.attributes == ["bass", "lead vocals"])
        #expect(artist.wikidataID == "Q1299")
        #expect(artist.links["discogs"]?.absoluteString == "https://www.discogs.com/artist/82730")
        #expect(artist.links["official homepage"]?.host == "www.thebeatles.com")
        let url = try #require(mock.lastRequest?.url?.absoluteString.removingPercentEncoding)
        #expect(url.contains("/ws/2/artist/b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d?"))
        #expect(url.contains("inc=url-rels+artist-rels+aliases"))
    }

    @Test("searchArtists returns best score first with disambiguation")
    func artistSearch() async throws {
        let mock = MockHTTPClient()
        mock.responseData = Bundle.fixtureData(named: "Fixtures/mb_artist_search.json")
        let results = try await self.makeClient(mock).searchArtists(name: "The Beatles")
        #expect(results.map(\.score) == [100, 72, 40])
        #expect(results.first?.id == "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d")
        #expect(results.last?.disambiguation == "film composer")
    }

    @Test("browseReleaseGroups decodes paging and types")
    func releaseGroupBrowse() async throws {
        let mock = MockHTTPClient()
        mock.responseData = Bundle.fixtureData(named: "Fixtures/mb_release_group_browse.json")
        let page = try await self.makeClient(mock).browseReleaseGroups(artistMBID: "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d")
        #expect(page.releaseGroupCount == 3)
        #expect(page.releaseGroups.map { $0.primaryType ?? "" } == ["Album", "Single", "Album"])
        #expect(page.releaseGroups.first?.year == 1963)
        let url = try #require(mock.lastRequest?.url?.absoluteString.removingPercentEncoding)
        #expect(url.contains("artist=b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"))
        #expect(url.contains("inc=artist-credits"))
    }

    @Test("503 maps to rateLimitExceeded and other errors to invalidResponse")
    func errors() async throws {
        let mock = MockHTTPClient()
        mock.statusCode = 503
        await #expect(throws: AcousticsError.rateLimitExceeded) {
            _ = try await self.makeClient(mock).searchArtists(name: "x")
        }
        mock.statusCode = 404
        await #expect(throws: AcousticsError.self) {
            _ = try await self.makeClient(mock).fetchArtist(mbid: "nope")
        }
    }

    @Test("the shared rate limiter is one instance")
    func sharedLimiter() {
        #expect(MusicBrainzClient.sharedRateLimiter === MusicBrainzClient.sharedRateLimiter)
    }
}
