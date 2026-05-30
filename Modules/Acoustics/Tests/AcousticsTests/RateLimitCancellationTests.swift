import Foundation
import Testing
@testable import Acoustics

// MARK: - RateLimitCancellationTests

/// Regression for #273: a cancelled lookup/fetch must not block a rate-limiter
/// slot and then fire its HTTP request anyway. Cancellation is checked both by
/// `RateLimiter.wait()` and again immediately after it returns, so a job
/// cancelled at any point before the request never hits the network.
@Suite("Rate-limited clients honour cancellation")
struct RateLimitCancellationTests {
    @Test("a cancelled AcoustID lookup throws and never fires the request")
    func cancelledLookupSkipsRequest() async throws {
        let mock = MockHTTPClient()
        let client = AcoustIDClient(
            apiKey: "test-key",
            rateLimiter: RateLimiter(maxRequests: 100, per: 1.0),
            httpClient: mock
        )

        let task = Task {
            try await client.lookup(fingerprint: "AQAAZ0mk", duration: 100)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(mock.callCount == 0, "cancelled lookup must not fire the HTTP request")
    }

    @Test("a cancelled MusicBrainz fetch throws and never fires the request")
    func cancelledFetchSkipsRequest() async throws {
        let mock = MockHTTPClient()
        let client = MusicBrainzClient(
            userAgent: "BocanTests/1.0 ( https://example.invalid )",
            rateLimiter: RateLimiter(maxRequests: 100, per: 1.0),
            httpClient: mock
        )

        let task = Task {
            try await client.fetchRecording(mbid: "00000000-0000-0000-0000-000000000000")
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(mock.callCount == 0, "cancelled fetch must not fire the HTTP request")
    }
}
