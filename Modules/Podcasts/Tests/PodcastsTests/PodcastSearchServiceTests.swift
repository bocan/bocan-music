import Foundation
import Testing
@testable import Podcasts

// MARK: - Helpers

private func makeHTTPResponse(status: Int) throws -> HTTPURLResponse {
    try stubResponse("https://example.com", status: status)
}

private func loadFixture(named name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
        "Fixture not found: \(name)"
    )
    return try Data(contentsOf: url)
}

// MARK: - Tests

@Suite("PodcastSearchService")
struct PodcastSearchServiceTests {
    // MARK: Headline regression: merge where both sources return the same show

    @Test("Both sources return the same show -- one merged result with both source tags")
    func bothSourcesMergeSameShow() async throws {
        // Podcast Index returns the show with an https/www URL; iTunes returns
        // the same show with an http/www URL. FeedURL.canonicalKey must match them.
        let piData = try loadFixture(named: "podcastindex-search.json")
        let itData = try loadFixture(named: "itunes-search.json")

        let mock = MockHTTPClient()
        mock.handler = { request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("podcastindex.org") {
                return try (piData, makeHTTPResponse(status: 200))
            }
            return try (itData, makeHTTPResponse(status: 200))
        }

        let service = PodcastSearchService(
            podcastIndex: PodcastIndexClient(
                credentials: PodcastIndexCredentials(apiKey: "k", apiSecret: "s"),
                http: mock
            ) { Date(timeIntervalSince1970: 1_717_200_000) },
            itunes: ITunesSearchClient(http: mock)
        )

        let results = try await service.search(term: "swift")

        // "Swift by Sundell" appears in both fixtures; must be one merged result.
        let sundell = results.first { $0.title == "Swift by Sundell" }
        let unwrapped = try #require(sundell)

        #expect(unwrapped.sources == [.podcastIndex, .itunes])
        // PI's data is preferred: description and artwork from PI fixture.
        #expect(unwrapped.description?.contains("building apps") == true)
        #expect(unwrapped.artworkURL?.absoluteString.contains("artwork-hd") == true)
        // Both IDs carried.
        #expect(unwrapped.podcastIndexID == 111)
        #expect(unwrapped.itunesCollectionID == 1_234_567)
        // Feed URL prefers https (PI already had https).
        #expect(unwrapped.feedURL.scheme == "https")
    }

    // MARK: Ordering: both-source first, PI-only second, iTunes-only last

    @Test("Both-source results sort before single-source results")
    func orderingBothSourceFirst() async throws {
        let piData = try loadFixture(named: "podcastindex-search.json")
        let itData = try loadFixture(named: "itunes-search.json")

        let mock = MockHTTPClient()
        mock.handler = { request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("podcastindex.org") {
                return try (piData, makeHTTPResponse(status: 200))
            }
            return try (itData, makeHTTPResponse(status: 200))
        }

        let service = PodcastSearchService(
            podcastIndex: PodcastIndexClient(
                credentials: PodcastIndexCredentials(apiKey: "k", apiSecret: "s"),
                http: mock
            ) { Date(timeIntervalSince1970: 1_717_200_000) },
            itunes: ITunesSearchClient(http: mock)
        )

        let results = try await service.search(term: "swift")

        // Expect 3 results total: 1 merged (both), 1 PI-only, 1 iTunes-only.
        // "No Feed URL Show" in the iTunes fixture has no feedUrl, so it is dropped.
        #expect(results.count == 3)
        #expect(results[0].sources.count == 2) // both-source first
        #expect(results[1].sources == [.podcastIndex]) // PI-only second
        #expect(results[2].sources == [.itunes]) // iTunes-only last
    }

    // MARK: PI-only and iTunes-only shows appear tagged with one source

    @Test("PI-only show tagged .podcastIndex; iTunes-only show tagged .itunes")
    func singleSourceTagging() async throws {
        let piData = try loadFixture(named: "podcastindex-search.json")
        let itData = try loadFixture(named: "itunes-search.json")

        let mock = MockHTTPClient()
        mock.handler = { request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("podcastindex.org") {
                return try (piData, makeHTTPResponse(status: 200))
            }
            return try (itData, makeHTTPResponse(status: 200))
        }

        let service = PodcastSearchService(
            podcastIndex: PodcastIndexClient(
                credentials: PodcastIndexCredentials(apiKey: "k", apiSecret: "s"),
                http: mock
            ) { Date(timeIntervalSince1970: 1_717_200_000) },
            itunes: ITunesSearchClient(http: mock)
        )

        let results = try await service.search(term: "swift")

        let piOnly = try #require(results.first { $0.title == "Podcast Index Only Show" })
        let itOnly = try #require(results.first { $0.title == "iTunes Only Show" })

        #expect(piOnly.sources == [.podcastIndex])
        #expect(itOnly.sources == [.itunes])
    }

    // MARK: Secondary title+author dedupe

    @Test("Secondary dedupe merges two results with matching title and author but different feed URLs")
    func secondaryTitleAuthorDedupe() throws {
        // Build two results that would not match on feed URL but share title+author.
        let piResult = try PodcastSearchResult(
            canonicalFeedKey: "tracking.example.com/pid/feed",
            feedURL: #require(URL(string: "https://tracking.example.com/pid/feed")),
            title: "Dev Discussions",
            author: "Alice Dev",
            episodeCount: 80,
            sources: [.podcastIndex],
            podcastIndexID: 999
        )
        let itResult = try PodcastSearchResult(
            canonicalFeedKey: "dev.example.com/feed.xml",
            feedURL: #require(URL(string: "https://dev.example.com/feed.xml")),
            title: "Dev Discussions!", // extra punctuation -- normalises to same key
            author: "Alice Dev",
            episodeCount: 78,
            sources: [.itunes],
            itunesCollectionID: 4567
        )

        let merged = PodcastSearchService.merge(piFeeds: [piResult], itFeeds: [itResult])

        #expect(merged.count == 1)
        #expect(merged[0].sources == [.podcastIndex, .itunes])
        // PI wins on the merge (preferred).
        #expect(merged[0].podcastIndexID == 999)
        #expect(merged[0].itunesCollectionID == 4567)
    }

    // MARK: Partial failure: one source fails

    @Test("One source failing still returns the other source's results")
    func oneSourceFailsOtherReturns() async throws {
        let itData = try loadFixture(named: "itunes-search.json")

        let mock = MockHTTPClient()
        mock.handler = { request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("podcastindex.org") {
                throw URLError(.notConnectedToInternet)
            }
            return try (itData, makeHTTPResponse(status: 200))
        }

        let service = PodcastSearchService(
            podcastIndex: PodcastIndexClient(
                credentials: PodcastIndexCredentials(apiKey: "k", apiSecret: "s"),
                http: mock
            ) { Date() },
            itunes: ITunesSearchClient(http: mock)
        )

        // Must not throw even though PI failed.
        let results = try await service.search(term: "swift")
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.sources == [.itunes] })
    }

    // MARK: All sources fail -> throw

    @Test("Both sources failing throws searchUnavailable")
    func bothSourcesFailThrows() async throws {
        let mock = MockHTTPClient()
        mock.handler = { _ in throw URLError(.notConnectedToInternet) }

        let service = PodcastSearchService(
            podcastIndex: PodcastIndexClient(
                credentials: PodcastIndexCredentials(apiKey: "k", apiSecret: "s"),
                http: mock
            ) { Date() },
            itunes: ITunesSearchClient(http: mock)
        )

        await #expect(throws: PodcastsError.self) {
            _ = try await service.search(term: "swift")
        }
    }

    // MARK: No Podcast Index credentials -> iTunes-only

    @Test("No Podcast Index credentials yields iTunes-only results without throwing")
    func noPodcastIndexCredentials() async throws {
        let itData = try loadFixture(named: "itunes-search.json")

        let mock = MockHTTPClient()
        mock.handler = { _ in try (itData, makeHTTPResponse(status: 200)) }

        // podcastIndex: nil -- no credentials configured.
        let service = PodcastSearchService(
            podcastIndex: nil,
            itunes: ITunesSearchClient(http: mock)
        )

        let results = try await service.search(term: "swift")
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.sources == [.itunes] })
    }

    // MARK: Empty / whitespace query

    @Test("Blank query returns empty array without network calls")
    func blankQueryReturnsEmpty() async throws {
        let mock = MockHTTPClient()
        var callCount = 0
        mock.handler = { _ in
            callCount += 1
            return try (Data(), makeHTTPResponse(status: 200))
        }

        let service = PodcastSearchService(
            podcastIndex: nil,
            itunes: ITunesSearchClient(http: mock)
        )

        let results = try await service.search(term: "   ")
        #expect(results.isEmpty)
        #expect(callCount == 0)
    }

    // MARK: Storefront (#605)

    @Test("The iTunes request carries the storefront country chosen in Settings")
    func searchCarriesChosenStorefront() async throws {
        let itData = try loadFixture(named: "itunes-search.json")
        let suite = "PodcastSearchServiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // What the Settings pane stores for "United Kingdom".
        defaults.set("gb", forKey: PodcastSettings.Key.storefront)

        let mock = MockHTTPClient()
        let recorder = RequestRecorder()
        mock.handler = { request in
            recorder.record(request)
            return try (itData, makeHTTPResponse(status: 200))
        }
        let service = PodcastSearchService(podcastIndex: nil, itunes: ITunesSearchClient(http: mock))

        _ = try await service.search(term: "swift", country: PodcastSettings(defaults: defaults).storefront)

        let url = try #require(recorder.requests.first?.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "country" }?.value == "GB")
    }

    @Test("The detail lookup uses the same storefront when iTunes is the only source")
    func detailCarriesChosenStorefront() async throws {
        let itData = try loadFixture(named: "itunes-search.json")
        let mock = MockHTTPClient()
        let recorder = RequestRecorder()
        mock.handler = { request in
            recorder.record(request)
            return try (itData, makeHTTPResponse(status: 200))
        }
        let service = PodcastSearchService(podcastIndex: nil, itunes: ITunesSearchClient(http: mock))
        let hit = try PodcastSearchResult(
            canonicalFeedKey: "example.com/feed.xml",
            feedURL: #require(URL(string: "https://example.com/feed.xml")),
            title: "Swift by Sundell",
            sources: [.itunes],
            itunesCollectionID: 1_234_567
        )

        _ = await service.detail(for: hit, country: "JP")

        let url = try #require(recorder.requests.first?.url)
        #expect(url.path == "/lookup")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "country" }?.value == "JP")
    }
}
