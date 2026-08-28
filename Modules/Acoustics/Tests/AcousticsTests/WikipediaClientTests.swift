import Foundation
import Testing
@testable import Acoustics

/// Routes the two Wikimedia hosts to their fixtures.
private final class RoutingHTTPClient: HTTPClient, @unchecked Sendable {
    var routes: [String: Data] = [:]
    private(set) var requestedURLs: [URL] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        self.requestedURLs.append(url)
        let key = self.routes.keys.first { url.absoluteString.contains($0) }
        let data = key.flatMap { self.routes[$0] } ?? Data()
        let status = key == nil ? 404 : 200
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@Suite("WikipediaClient (#412)")
struct WikipediaClientTests {
    private func makeClient(_ http: RoutingHTTPClient) -> WikipediaClient {
        WikipediaClient(
            userAgent: "Bocan/test ( https://bocan.app )",
            rateLimiter: RateLimiter(maxRequests: 100, per: 1.0),
            httpClient: http
        )
    }

    @Test("a Wikidata id resolves to the English summary with extract, page URL and thumbnail")
    func wikidataToSummary() async throws {
        let http = RoutingHTTPClient()
        http.routes["wikidata.org/wiki/Special:EntityData/Q1299.json"] = Bundle.fixtureData(named: "Fixtures/wikidata_entity.json")
        http.routes["en.wikipedia.org/api/rest_v1/page/summary/The_Beatles"] = Bundle.fixtureData(named: "Fixtures/wikipedia_summary.json")
        let summary = try #require(try await self.makeClient(http).summary(wikidataID: "Q1299"))
        #expect(summary.title == "The Beatles")
        #expect(summary.extract.hasPrefix("The Beatles were an English rock band"))
        #expect(summary.pageURL?.absoluteString == "https://en.wikipedia.org/wiki/The_Beatles")
        #expect(summary.thumbnailURL?.host == "upload.wikimedia.org")
        #expect(http.requestedURLs.count == 2)
    }

    @Test("an item without an English sitelink yields nil without a second request")
    func noEnglishArticle() async throws {
        let http = RoutingHTTPClient()
        http
            .routes["Special:EntityData/Q999.json"] = Data(
                #"{"entities":{"Q999":{"id":"Q999","sitelinks":{"dewiki":{"site":"dewiki","title":"X"}}}}}"#
                    .utf8
            )
        let summary = try await self.makeClient(http).summary(wikidataID: "Q999")
        #expect(summary == nil)
        #expect(http.requestedURLs.count == 1)
    }
}
