import XCTest

// MARK: - E2EPodcastServerTests

/// Verifies `E2EPodcastServer`'s responses directly, byte-for-byte, before
/// any Podcasts-module parsing gets near them — mirrors
/// `E2EStreamServerTests`'s rationale: a bug here would otherwise surface as
/// an opaque feed-parse or decode failure three steps away inside a full
/// journey.
///
/// Uses `URLSession` directly rather than a hand-rolled client: every
/// response is `Content-Length`-terminated (episode downloads and feed
/// fetches are finite, unlike the radio server's open-ended `/stream`), so
/// a normal data task completes cleanly.
final class E2EPodcastServerTests: XCTestCase {
    func testFeedAdvertisesTheShowTitleAndTwoEpisodes() async throws {
        let server = try E2EPodcastServer(showTitle: "Unit Test Cast")
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(from: server.feedURL)
        let xml = String(bytes: data, encoding: .utf8) ?? ""

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(xml.contains("<title>Unit Test Cast</title>"))
        XCTAssertEqual(xml.components(separatedBy: "<item>").count - 1, 2, "exactly two episodes before publishThirdEpisode()")
        XCTAssertTrue(xml.contains("Episode One"))
        XCTAssertTrue(xml.contains("Episode Two"))
        XCTAssertFalse(xml.contains("Episode Three"))
    }

    func testEpisodeOneCarriesChaptersEpisodeTwoDoesNot() async throws {
        let server = try E2EPodcastServer()
        defer { server.stop() }

        let (data, _) = try await URLSession.shared.data(from: server.feedURL)
        let xml = String(bytes: data, encoding: .utf8) ?? ""

        let items = xml.components(separatedBy: "<item>").dropFirst()
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[items.startIndex].contains("podcast:chapters"), "episode one must carry chapters")
        XCTAssertFalse(items[items.startIndex + 1].contains("podcast:chapters"), "episode two must not carry chapters")
    }

    func testPublishThirdEpisodeAddsItToTheNextFetch() async throws {
        let server = try E2EPodcastServer()
        defer { server.stop() }

        server.publishThirdEpisode()
        // Queue-confined write; give it a beat to land before the fetch.
        try await Task.sleep(nanoseconds: 100_000_000)

        let (data, _) = try await URLSession.shared.data(from: server.feedURL)
        let xml = String(bytes: data, encoding: .utf8) ?? ""

        XCTAssertEqual(xml.components(separatedBy: "<item>").count - 1, 3)
        XCTAssertTrue(xml.contains("Episode Three"))
    }

    func testEpisodeAudioServesTheSynthesizedWAV() async throws {
        let server = try E2EPodcastServer(episodeSeconds: 1)
        defer { server.stop() }

        let episodeURL = server.feedURL.deletingLastPathComponent().appendingPathComponent("ep1.wav")
        let (data, response) = try await URLSession.shared.data(from: episodeURL)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
        XCTAssertEqual(data, PodcastFixtureAudio.makeWAV(seconds: 1))
    }

    func testChaptersJSONIsServedForEpisodeOne() async throws {
        let server = try E2EPodcastServer()
        defer { server.stop() }

        let chaptersURL = server.feedURL.deletingLastPathComponent().appendingPathComponent("ep1-chapters.json")
        let (data, response) = try await URLSession.shared.data(from: chaptersURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertNotNil(json?["chapters"] as? [[String: Any]])
    }

    func testUnknownPathReturns404() async throws {
        let server = try E2EPodcastServer()
        defer { server.stop() }

        let url = server.feedURL.deletingLastPathComponent().appendingPathComponent("nope")
        let (_, response) = try await URLSession.shared.data(from: url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
    }
}
