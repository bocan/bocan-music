import Foundation
import Testing
@testable import SyncServer

/// #471: without `LocalizedError`, `localizedDescription` is Foundation's
/// fallback, which reads "(SyncServer.SyncServerError error 3.)". This enum had
/// no message text at all, so the description is new here too.
@Suite("SyncServer error messages")
struct ErrorMessageTests {
    @Test("SyncServerError carries its reason through localizedDescription")
    func syncServerError() {
        let cases: [SyncServerError] = [
            .pairing(reason: "codeMismatch"),
            .identity(reason: "keychainUnavailable", status: -25300),
            .identity(reason: "inMemoryHasNoSecIdentity", status: nil),
            .transcodeSourceUnavailable(trackID: 42),
        ]
        for error in cases {
            #expect(error.errorDescription == error.description)
            #expect(error.localizedDescription == error.description)
            #expect(
                error.localizedDescription.range(of: #"error \d"#, options: .regularExpression) == nil,
                "still shows a Foundation error code: \(error.localizedDescription)"
            )
        }

        // The status is included when there is one and omitted when there is not.
        #expect(SyncServerError.identity(reason: "x", status: -25300).localizedDescription.contains("-25300"))
        #expect(!SyncServerError.identity(reason: "x", status: nil).localizedDescription.contains("status"))
    }
}
