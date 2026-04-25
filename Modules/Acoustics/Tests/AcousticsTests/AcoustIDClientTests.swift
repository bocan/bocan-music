import Foundation
import Testing
@testable import Acoustics

@Suite("AcoustIDClient")
struct AcoustIDClientTests {
    private func makeClient(mock: MockHTTPClient) -> AcoustIDClient {
        AcoustIDClient(
            apiKey: "test-key",
            rateLimiter: RateLimiter(maxRequests: 100, per: 1.0),
            httpClient: mock
        )
    }

    // MARK: - Single result

    @Test("single result: returns one candidate with correct score")
    func singleResult() async throws {
        let mock = MockHTTPClient()
        mock.responseData = Bundle.fixtureData(named: "Fixtures/acoustid_response_single.json")
        let client = self.makeClient(mock: mock)
        let results = try await client.lookup(fingerprint: "AQAAZ0mk", duration: 259)
        #expect(results.count == 1)
        #expect(results[0].id == "2dd41a10-3b4c-4bcd-87dc-c49dda6b5660")
        #expect(abs(results[0].score - 0.9474620819091797) < 0.0001)
        #expect(results[0].recordings?.first?.title == "Come Together")
    }

    // MARK: - Multi-result ordering

    @Test("multi result: sorted by score descending")
    func multiResultSorted() async throws {
        let mock = MockHTTPClient()
        mock.responseData = Bundle.fixtureData(named: "Fixtures/acoustid_response_multi.json")
        let client = self.makeClient(mock: mock)
        let results = try await client.lookup(fingerprint: "AQAAZ0mk", duration: 259)
        #expect(results.count == 3)
        #expect(results[0].score >= results[1].score)
        #expect(results[1].score >= results[2].score)
    }

    // MARK: - HTTP 429

    @Test("HTTP 429 throws rateLimitExceeded")
    func http429() async {
        let mock = MockHTTPClient()
        mock.statusCode = 429
        mock.responseData = Data()
        let client = self.makeClient(mock: mock)
        await #expect(throws: AcousticsError.rateLimitExceeded) {
            try await client.lookup(fingerprint: "fp", duration: 100)
        }
    }

    // MARK: - Network error

    @Test("network error wraps in networkError")
    func networkError() async {
        let mock = MockHTTPClient()
        mock.error = URLError(.notConnectedToInternet)
        let client = self.makeClient(mock: mock)
        await #expect(throws: AcousticsError.self) {
            try await client.lookup(fingerprint: "fp", duration: 100)
        }
    }

    // MARK: - Non-2xx

    @Test("HTTP 500 throws invalidResponse")
    func http500() async {
        let mock = MockHTTPClient()
        mock.statusCode = 500
        mock.responseData = Data("error".utf8)
        let client = self.makeClient(mock: mock)
        await #expect(throws: AcousticsError.self) {
            try await client.lookup(fingerprint: "fp", duration: 100)
        }
    }
}
