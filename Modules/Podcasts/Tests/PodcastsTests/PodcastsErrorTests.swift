import Foundation
import Testing
@testable import Podcasts

@Suite("PodcastsError")
struct PodcastsErrorTests {
    /// Repro for the bare "Podcasts.PodcastsError error 1." rendering: a plain
    /// enum error's `localizedDescription` is the runtime's case-index string.
    /// `LocalizedError` conformance must surface the case description instead.
    @Test("LocalizedError conformance surfaces the case description, not bare \"error 1\"")
    func networkCaseLocalizedDescription() {
        let underlying = URLError(.appTransportSecurityRequiresSecureConnection)
        let error = PodcastsError.network(underlying: underlying)

        #expect(error.errorDescription == error.description)
        #expect(error.errorDescription?.hasPrefix("Network error:") == true)
        #expect(error.errorDescription?.contains(underlying.localizedDescription) == true)
        #expect(error.localizedDescription == error.description)
        #expect(error.localizedDescription.contains("error 1") == false)
    }

    @Test("errorDescription matches description for representative cases")
    func representativeCases() throws {
        let parse = try PodcastsError.parseFailed(
            url: #require(URL(string: "https://example.org/feed")),
            reason: "truncated"
        )
        #expect(parse.errorDescription == parse.description)

        let status = try PodcastsError.httpStatus(
            code: 404,
            url: #require(URL(string: "https://example.org/feed"))
        )
        #expect(status.errorDescription == status.description)
        #expect(status.errorDescription?.hasPrefix("HTTP 404") == true)
    }
}
