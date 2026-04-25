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
