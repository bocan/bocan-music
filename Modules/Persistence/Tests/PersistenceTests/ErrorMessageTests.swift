import Foundation
import Testing
@testable import Persistence

/// #471: without `LocalizedError`, `localizedDescription` is Foundation's
/// fallback, which reads "(Persistence.PersistenceError error 3.)".
@Suite("Persistence error messages")
struct ErrorMessageTests {
    @Test("PersistenceError carries its reason through localizedDescription")
    func persistenceError() {
        let cases: [PersistenceError] = [
            .integrityCheckFailed(details: "page 4"),
            .notFound(entity: "Track", id: 12),
            .uniqueConstraintViolation(table: "tracks", column: "file_url"),
            .bookmarkResolutionFailed(reason: "stale"),
        ]
        for error in cases {
            #expect(error.errorDescription == error.description)
            #expect(error.localizedDescription == error.description)
            #expect(
                error.localizedDescription.range(of: #"error \d"#, options: .regularExpression) == nil,
                "still shows a Foundation error code: \(error.localizedDescription)"
            )
        }
        #expect(PersistenceError.notFound(entity: "Track", id: 12).localizedDescription.contains("Track"))
    }
}
