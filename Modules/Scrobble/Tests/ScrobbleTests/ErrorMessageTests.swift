import Foundation
import Testing
@testable import Scrobble

/// #471: the Settings panes put this straight into their error fields, so
/// before the fix a failed sign-in showed a raw Swift case dump such as
/// `notAuthenticated(provider: "lastfm")`. This enum had no message text at
/// all, so the description is new here too.
@Suite("Scrobble error messages")
struct ErrorMessageTests {
    @Test("ScrobbleError carries its reason through localizedDescription")
    func scrobbleError() {
        let cases: [ScrobbleError] = [
            .notAuthenticated(provider: "Last.fm"),
            .invalidCredentials(provider: "Last.fm"),
            .transient(provider: "ListenBrainz", reason: "rate limited", retryAfter: 60),
            .permanent(provider: "Rocksky", reason: "rejected"),
            .offline,
            .timestampOutOfRange,
            .keychain(status: -25300, message: "read failed"),
            .malformedResponse(provider: "Last.fm", reason: "no body"),
            .authTimeout,
            .authCancelled,
        ]
        for error in cases {
            #expect(error.errorDescription == error.description)
            #expect(error.localizedDescription == error.description)
            #expect(
                error.localizedDescription.range(of: #"error \d"#, options: .regularExpression) == nil,
                "still shows a Foundation error code: \(error.localizedDescription)"
            )
        }

        // The provider is named, and no Swift case dump survives.
        let notSignedIn = ScrobbleError.notAuthenticated(provider: "Last.fm")
        #expect(notSignedIn.localizedDescription.contains("Last.fm"))
        #expect(!notSignedIn.localizedDescription.contains("notAuthenticated"))
    }
}
