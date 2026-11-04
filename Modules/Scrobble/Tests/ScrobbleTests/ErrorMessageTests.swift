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

    /// #677: a love and a now-playing update are sent once, so their failure
    /// logs must not promise the queue's retry or offline wait.
    @Test("causeDescription states the cause without the queue's next step")
    func causeDescriptionMakesNoQueuePromise() {
        let transient = ScrobbleError.transient(provider: "rocksky", reason: "http 500", retryAfter: nil)
        #expect(transient.description.contains("It will be retried"))
        #expect(transient.causeDescription == "rocksky is temporarily unavailable: http 500.")

        let permanent = ScrobbleError.permanent(provider: "lastfm", reason: "track not found")
        #expect(permanent.causeDescription == "lastfm rejected the request: track not found")

        #expect(ScrobbleError.offline.causeDescription == "No network connection.")

        let unchanged = ScrobbleError.invalidCredentials(provider: "lastfm")
        #expect(unchanged.causeDescription == unchanged.description)

        let cases: [ScrobbleError] = [transient, permanent, .offline]
        for error in cases {
            let text = ScrobbleError.causeDescription(of: error)
            #expect(!text.contains("retried"), "still promises a retry: \(text)")
            #expect(!text.contains("queued"), "still promises the queue: \(text)")
            #expect(!text.contains("play"), "still names a play: \(text)")
        }

        // An error from outside the module keeps the reflection the catch
        // block logged before, which sees it as `any Error`.
        let other: any Error = URLError(.timedOut)
        #expect(ScrobbleError.causeDescription(of: other) == String(reflecting: other))
    }

    /// A log line cannot be read back from a test, so pin the wiring in source.
    @Test("love and now-playing failure logs use causeDescription")
    func oneShotFailureLogsUseCause() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ScrobbleTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/Scrobble/
            .appendingPathComponent("Sources/Scrobble/ScrobbleService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for event in ["scrobble.service.love.fail", "scrobble.service.nowplaying.fail"] {
            let start = try #require(source.range(of: event), "missing \(event)")
            let tail = source[start.upperBound...].prefix(300)
            #expect(tail.contains("ScrobbleError.causeDescription(of: error)"), "\(event) does not use causeDescription")
            #expect(tail.contains("not sent, not retried"), "\(event) does not say the request is final")
        }
    }
}
