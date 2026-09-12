import Foundation
import Testing
@testable import Playback

/// #471: without `LocalizedError`, `localizedDescription` is Foundation's
/// fallback, which reads "(Playback.PlaybackError error 3.)". The UI shows
/// `localizedDescription`, so the reason has to survive it.
@Suite("Playback error messages")
struct ErrorMessageTests {
    @Test("PlaybackError carries its reason through localizedDescription")
    func playbackError() {
        let cases: [PlaybackError] = [
            .noBookmark(trackID: 12),
            .trackNotFound(id: 12),
            .queueEmpty,
            .incompatibleFormat(reason: "sample rate"),
        ]
        for error in cases {
            #expect(error.errorDescription == error.description)
            #expect(error.localizedDescription == error.description)
            #expect(
                error.localizedDescription.range(of: #"error \d"#, options: .regularExpression) == nil,
                "still shows a Foundation error code: \(error.localizedDescription)"
            )
        }
        #expect(PlaybackError.queueEmpty.localizedDescription.contains("queue is empty"))
    }
}
