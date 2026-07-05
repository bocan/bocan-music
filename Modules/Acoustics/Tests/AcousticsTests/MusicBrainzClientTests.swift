import Foundation
import Testing
@testable import Acoustics

@Suite("MusicBrainzClient")
struct MusicBrainzClientTests {
    private let userAgent = "Bocan/1.0 ( https://github.com/bocan/bocan-music )"

    private func makeClient(mock: MockHTTPClient) -> MusicBrainzClient {
        MusicBrainzClient(
            userAgent: self.userAgent,
            rateLimiter: RateLimiter(maxRequests: 100, per: 1.0),
            httpClient: mock
        )
    }

    // MARK: - Happy path

    @Test("fetchRecording decodes fixture correctly")
    func decodesFixture() async throws {
        let mock = MockHTTPClient()
        mock.responseData = Bundle.fixtureData(named: "Fixtures/mb_recording_response.json")
        let client = self.makeClient(mock: mock)
        let recording = try await client.fetchRecording(mbid: "f76e9be1-bd30-4b26-b0a6-1b8e9c70e4df")
        #expect(recording.id == "f76e9be1-bd30-4b26-b0a6-1b8e9c70e4df")
        #expect(recording.title == "Come Together")
        #expect(recording.artistName == "The Beatles")
        #expect(recording.releases?.first?.title == "Abbey Road")
        #expect(recording.releases?.first?.year == 1969)
        #expect(recording.releases?.first?.labelInfo?.first?.label?.name == "Apple Records")
        #expect(recording.topGenre == "Rock")
    }

    // MARK: - Expanded inc= response (recorded from the live API, 2026-07-05)

    @Test("fetchRecording decodes the expanded multi-release fixture")
    func decodesMultiReleaseFixture() async throws {
        let mock = MockHTTPClient()
        mock.responseData = Bundle.fixtureData(named: "Fixtures/mb_recording_response_multi_release.json")
        let client = self.makeClient(mock: mock)
        let recording = try await client.fetchRecording(mbid: "485bbe7f-d0f7-4ffe-8adb-0f1093dd2dbf")

        #expect(recording.title == "Come Together")
        #expect(recording.isrcs == ["GBAYE0000944", "GBAYE0601690"])

        let releases = try #require(recording.releases)
        #expect(releases.count == 25)

        // The earliest official release in the recorded data: 1969 Spanish Abbey Road LP.
        let earliest = try #require(releases.first { $0.id == "03437e02-835f-3a0a-a37c-48a36c2e852a" })
        #expect(earliest.status == "Official")
        #expect(earliest.country == "ES")
        #expect(earliest.date == "1969")
        #expect(earliest.year == 1969)
        #expect(earliest.releaseGroup?.id == "9162580e-5df4-32de-80cc-f45a8d8a9b1d")
        #expect(earliest.releaseGroup?.primaryType == "Album")
        #expect(earliest.releaseGroup?.secondaryTypes ?? [] == [])

        let medium = try #require(earliest.media?.first { !($0.tracks ?? []).isEmpty })
        #expect(medium.format == "12\" Vinyl")
        #expect(medium.trackCount == 17)
        #expect(medium.tracks?.first?.trackNumber == 1)

        // Compilations are flagged via release-group secondary types.
        let compilations = releases.filter { !($0.releaseGroup?.secondaryTypes ?? []).isEmpty }
        #expect(compilations.count == 10)

        // The recording endpoint cannot return label-info (labels is not a valid
        // inc parameter there) — recorded data must reflect that.
        #expect(releases.allSatisfy { $0.labelInfo == nil })
    }

    @Test("MBRecording decodes when every optional key is absent")
    func decodesMinimalRecording() throws {
        let json = Data(#"{"id": "abc", "title": "Bare"}"#.utf8)
        let recording = try JSONDecoder().decode(MBRecording.self, from: json)
        #expect(recording.id == "abc")
        #expect(recording.isrcs == nil)
        #expect(recording.releases == nil)
        #expect(recording.artistName.isEmpty)
    }

    @Test("Release decodes when optional keys are absent")
    func decodesMinimalRelease() throws {
        let json = Data(#"{"id": "r", "title": "Bare", "releases": [{"id": "x", "title": "Y"}]}"#.utf8)
        let recording = try JSONDecoder().decode(MBRecording.self, from: json)
        let release = try #require(recording.releases?.first)
        #expect(release.country == nil)
        #expect(release.releaseGroup == nil)
        #expect(release.media == nil)
        #expect(release.year == nil)
    }

    // MARK: - inc= parameter

    @Test("Request asks for release-groups, isrcs, and media — and never labels")
    func incParameter() async throws {
        let mock = MockHTTPClient()
        mock.responseData = Bundle.fixtureData(named: "Fixtures/mb_recording_response.json")
        let capture = RequestBox()
        let capturingClient = CapturingHTTPClient(inner: mock) { capture.request = $0 }
        let client = MusicBrainzClient(
            userAgent: userAgent,
            rateLimiter: RateLimiter(maxRequests: 100, per: 1.0),
            httpClient: capturingClient
        )
        _ = try await client.fetchRecording(mbid: "some-mbid")
        let query = try #require(capture.request?.url?.query())
        #expect(query.contains("release-groups"))
        #expect(query.contains("isrcs"))
        #expect(query.contains("media"))
        // "labels" is rejected by the recording resource with an HTTP error.
        #expect(!query.contains("labels"))
    }

    // MARK: - User-Agent header

    @Test("User-Agent header is present and correct")
    func userAgentHeader() async throws {
        let mock = MockHTTPClient()
        mock.responseData = Bundle.fixtureData(named: "Fixtures/mb_recording_response.json")
        let capture = RequestBox()
        let capturingClient = CapturingHTTPClient(inner: mock) { capture.request = $0 }
        let client = MusicBrainzClient(
            userAgent: userAgent,
            rateLimiter: RateLimiter(maxRequests: 100, per: 1.0),
            httpClient: capturingClient
        )
        _ = try await client.fetchRecording(mbid: "f76e9be1-bd30-4b26-b0a6-1b8e9c70e4df")
        #expect(capture.request?.value(forHTTPHeaderField: "User-Agent") == self.userAgent)
    }

    // MARK: - HTTP 503 (MB rate limit)

    @Test("HTTP 503 throws rateLimitExceeded")
    func http503() async {
        let mock = MockHTTPClient()
        mock.statusCode = 503
        mock.responseData = Data()
        let client = self.makeClient(mock: mock)
        await #expect(throws: AcousticsError.rateLimitExceeded) {
            try await client.fetchRecording(mbid: "some-mbid")
        }
    }

    // MARK: - HTTP 404

    @Test("HTTP 404 throws invalidResponse")
    func http404() async {
        let mock = MockHTTPClient()
        mock.statusCode = 404
        mock.responseData = Data()
        let client = self.makeClient(mock: mock)
        await #expect(throws: AcousticsError.self) {
            try await client.fetchRecording(mbid: "unknown-mbid")
        }
    }
}

// MARK: - Helpers

/// Thread-safe box for capturing a request in tests.
final class RequestBox: @unchecked Sendable {
    var request: URLRequest?
}

/// Helper that wraps another HTTPClient and calls a closure with each request.
final class CapturingHTTPClient: HTTPClient, @unchecked Sendable {
    private let inner: any HTTPClient
    private let onRequest: @Sendable (URLRequest) -> Void

    init(inner: any HTTPClient, onRequest: @Sendable @escaping (URLRequest) -> Void) {
        self.inner = inner
        self.onRequest = onRequest
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.onRequest(request)
        return try await self.inner.data(for: request)
    }
}
