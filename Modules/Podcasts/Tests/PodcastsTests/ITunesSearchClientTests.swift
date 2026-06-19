import Foundation
import Testing
@testable import Podcasts

@Suite("ITunesSearchClient")
struct ITunesSearchClientTests {
    private func makeOKResponse() -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://itunes.apple.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func loadFixture() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "itunes-search.json",
            withExtension: nil,
            subdirectory: "Fixtures"
        ),
            let data = try? Data(contentsOf: url) else {
            throw PodcastsError.parseFailed(
                url: URL(string: "test://itunes-search.json")!,
                reason: "itunes-search.json fixture not found"
            )
        }
        return data
    }

    @Test("search decodes itunes-search.json and drops rows without feedUrl")
    func searchDecodesAndFilters() async throws {
        let data = try loadFixture()
        let mock = MockHTTPClient()
        mock.handler = { _ in (data, self.makeOKResponse()) }

        let client = ITunesSearchClient(http: mock)
        let results = try await client.search(term: "swift")

        // Fixture has 3 entries but one has no feedUrl -- expect 2 results.
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.sources == [.itunes] })
    }

    @Test("All results from search are sourced .itunes")
    func sourcesAreItunes() async throws {
        let data = try loadFixture()
        let mock = MockHTTPClient()
        mock.handler = { _ in (data, self.makeOKResponse()) }

        let client = ITunesSearchClient(http: mock)
        let results = try await client.search(term: "swift")
        #expect(results.allSatisfy { $0.sources == [.itunes] })
    }

    @Test("search picks artworkUrl600 as the artwork URL (largest available)")
    func artworkUrl600Preferred() async throws {
        let data = try loadFixture()
        let mock = MockHTTPClient()
        mock.handler = { _ in (data, self.makeOKResponse()) }

        let client = ITunesSearchClient(http: mock)
        let results = try await client.search(term: "swift")

        let sundell = try #require(results.first { $0.title == "Swift by Sundell" })
        #expect(sundell.artworkURL?.absoluteString.contains("600") == true)
    }

    @Test("search decodes itunesCollectionID and categories correctly")
    func fieldMapping() async throws {
        let data = try loadFixture()
        let mock = MockHTTPClient()
        mock.handler = { _ in (data, self.makeOKResponse()) }

        let client = ITunesSearchClient(http: mock)
        let results = try await client.search(term: "swift")

        let sundell = try #require(results.first { $0.title == "Swift by Sundell" })
        #expect(sundell.itunesCollectionID == 1_234_567)
        #expect(sundell.categories.contains("Technology"))
        #expect(sundell.episodeCount == 115)
    }

    @Test("row without feedUrl is dropped from results")
    func noFeedUrlDropped() async throws {
        let data = try loadFixture()
        let mock = MockHTTPClient()
        mock.handler = { _ in (data, self.makeOKResponse()) }

        let client = ITunesSearchClient(http: mock)
        let results = try await client.search(term: "swift")

        #expect(results.first { $0.title == "No Feed URL Show" } == nil)
    }

    @Test("lookup returns a single result for the given collectionId")
    func lookupReturnsResult() async throws {
        // Reuse itunes-search.json -- the lookup endpoint returns the same shape.
        let data = try loadFixture()
        let mock = MockHTTPClient()
        mock.handler = { _ in (data, self.makeOKResponse()) }

        let client = ITunesSearchClient(http: mock)
        let result = try await client.lookup(collectionID: 1_234_567)
        let r = try #require(result)
        #expect(r.title == "Swift by Sundell")
    }
}
