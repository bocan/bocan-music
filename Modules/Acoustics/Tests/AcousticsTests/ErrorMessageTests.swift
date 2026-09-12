import Foundation
import Testing
@testable import Acoustics

/// #471: without `LocalizedError`, `localizedDescription` is Foundation's
/// fallback, which reads "(Acoustics.AcousticsError error 3.)". This enum had
/// no message text at all before, so the description is new here too.
@Suite("Acoustics error messages")
struct ErrorMessageTests {
    @Test("AcousticsError carries its reason through localizedDescription")
    func acousticsError() {
        let cases: [AcousticsError] = [
            .fpcalcFailed(exitCode: 2, stderr: "no such file"),
            .rateLimitExceeded,
            .noResults,
            .invalidResponse(reason: "not json"),
            .invalidInput(reason: "file path contains a NUL byte"),
        ]
        for error in cases {
            #expect(error.errorDescription == error.description)
            #expect(error.localizedDescription == error.description)
            #expect(
                error.localizedDescription.range(of: #"error \d"#, options: .regularExpression) == nil,
                "still shows a Foundation error code: \(error.localizedDescription)"
            )
        }
        #expect(AcousticsError.noResults.localizedDescription.contains("No matching recording"))
    }
}
