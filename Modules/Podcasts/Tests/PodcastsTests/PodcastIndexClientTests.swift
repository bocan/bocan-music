import CryptoKit
import Foundation
import Testing
@testable import Podcasts

@Suite("PodcastIndexClient")
struct PodcastIndexClientTests {
    private static let fixedNow = Date(timeIntervalSince1970: 1_717_200_000)
    private static let credentials = PodcastIndexCredentials(apiKey: "testkey", apiSecret: "testsecret")

    // MARK: Auth header signing (headline regression test)

    @Test("Auth headers contain correct keys and a valid 40-char SHA-1 hex Authorization")
    func authHeadersSHA1() {
        let headers = PodcastIndexAuth.headers(credentials: Self.credentials, now: Self.fixedNow)

        #expect(headers["X-Auth-Key"] == "testkey")
        #expect(headers["X-Auth-Date"] == "1717200000")

        // Independently compute the expected SHA-1 to verify algorithm and input order.
        let input = "testkey" + "testsecret" + "1717200000"
        let expected = Insecure.SHA1.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()

        #expect(headers["Authorization"] == expected)
        // SHA-1 digest is always 40 hex chars.
        #expect(headers["Authorization"]?.count == 40)
        #expect(headers["Authorization"]?.allSatisfy(\.isHexDigit) == true)
    }

    // MARK: Search decoding

    @Test("search decodes podcastindex-search.json into PodcastSearchResults sourced .podcastIndex")
    func searchDecodesFixture() async throws {
        guard let url = Bundle.module.url(
            forResource: "podcastindex-search.json",
            withExtension: nil,
            subdirectory: "Fixtures"
        ),
            let data = try? Data(contentsOf: url) else {
            Issue.record("podcastindex-search.json fixture not found")
            return
        }

        let mock = MockHTTPClient()
        mock.handler = { _ in
            (data, HTTPURLResponse(
                url: URL(string: "https://api.podcastindex.org")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!)
        }

        let client = PodcastIndexClient(
            credentials: Self.credentials,
            http: mock,
            now: { Self.fixedNow }
        )

        let results = try await client.search(term: "swift")

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.sources == [.podcastIndex] })

        let sundell = try #require(results.first { $0.title == "Swift by Sundell" })
        #expect(sundell.podcastIndexID == 111)
        #expect(sundell.author == "John Sundell")
        #expect(sundell.episodeCount == 120)
        #expect(sundell.categories.contains("Technology"))
        #expect(sundell.categories.contains("Software How-To"))
        #expect(sundell.artworkURL?.absoluteString.contains("artwork-hd") == true)
    }

    // MARK: byfeedurl decoding

    @Test("podcast(byFeedURL:) decodes podcastindex-byfeedurl.json correctly")
    func byFeedURLDecodes() async throws {
        guard let url = Bundle.module.url(
            forResource: "podcastindex-byfeedurl.json",
            withExtension: nil,
            subdirectory: "Fixtures"
        ),
            let data = try? Data(contentsOf: url) else {
            Issue.record("podcastindex-byfeedurl.json fixture not found")
            return
        }

        let mock = MockHTTPClient()
        mock.handler = { _ in
            (data, HTTPURLResponse(
                url: URL(string: "https://api.podcastindex.org")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!)
        }

        let client = PodcastIndexClient(
            credentials: Self.credentials,
            http: mock,
            now: { Self.fixedNow }
        )

        let feedURL = try #require(URL(string: "https://www.swiftbysundell.com/feed/podcast/"))
        let result = try await client.podcast(byFeedURL: feedURL)

        let r = try #require(result)
        #expect(r.title == "Swift by Sundell")
        #expect(r.episodeCount == 121)
        #expect(r.description?.contains("enriched") == true)
    }

    // MARK: HTTP 401 throws searchUnavailable

    @Test("HTTP 401 response throws searchUnavailable with source podcastIndex")
    func http401ThrowsSearchUnavailable() async throws {
        let mock = MockHTTPClient()
        mock.handler = { _ in
            (Data(), HTTPURLResponse(
                url: URL(string: "https://api.podcastindex.org")!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!)
        }

        let client = PodcastIndexClient(
            credentials: Self.credentials,
            http: mock,
            now: { Self.fixedNow }
        )

        do {
            _ = try await client.search(term: "test")
            Issue.record("Expected searchUnavailable to be thrown")
        } catch let PodcastsError.searchUnavailable(source, _) {
            #expect(source == "podcastIndex")
        }
    }

    // MARK: Auth headers sent in request

    @Test("Three PI auth headers are sent with every request")
    func authHeadersSentInRequest() async {
        let mock = MockHTTPClient()
        var capturedHeaders: [String: String] = [:]
        mock.handler = { request in
            capturedHeaders = request.allHTTPHeaderFields ?? [:]
            return (
                Data("{\"feeds\":[]}".utf8),
                HTTPURLResponse(
                    url: URL(string: "https://api.podcastindex.org")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        let client = PodcastIndexClient(
            credentials: Self.credentials,
            http: mock,
            now: { Self.fixedNow }
        )

        _ = try? await client.search(term: "test")

        #expect(capturedHeaders["X-Auth-Key"] == "testkey")
        #expect(capturedHeaders["X-Auth-Date"] != nil)
        #expect(capturedHeaders["Authorization"] != nil)
    }
}
