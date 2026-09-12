import Foundation
import Testing
@testable import Library

/// #471: a plain `Error` enum's `localizedDescription` is Foundation's fallback,
/// which reads "(Library.EditError error 3.)". The UI and App layers show
/// `localizedDescription` in 37 places, so every module error enum must carry
/// its reason through it. Four of them live in this module.
@Suite("Library error messages")
struct ErrorMessageTests {
    /// The defect this issue exists to remove: a Foundation error code where a
    /// reason should be.
    private func expectNoErrorCode(_ message: String, _ label: String) {
        #expect(
            message.range(of: #"error \d"#, options: .regularExpression) == nil,
            "\(label) still shows a Foundation error code: \(message)"
        )
    }

    @Test("LibraryError carries its reason through localizedDescription")
    func libraryError() {
        let cases: [LibraryError] = [
            .invalidPath("/nope"),
            .scanAlreadyInProgress,
            .databaseUnavailable("locked"),
            .listenExportUnreadable(reason: "truncated"),
        ]
        for error in cases {
            #expect(error.errorDescription == error.description)
            #expect(error.localizedDescription == error.description)
            self.expectNoErrorCode(error.localizedDescription, "LibraryError")
        }
        #expect(LibraryError.invalidPath("/nope").localizedDescription.contains("/nope"))
    }

    @Test("PlaylistError carries its reason through localizedDescription")
    func playlistError() {
        let cases: [PlaylistError] = [
            .notFound(7),
            .emptyName,
            .invalidAccentColor("nope"),
        ]
        for error in cases {
            #expect(error.errorDescription == error.description)
            #expect(error.localizedDescription == error.description)
            self.expectNoErrorCode(error.localizedDescription, "PlaylistError")
        }
        #expect(PlaylistError.notFound(7).localizedDescription.contains("7"))
    }

    @Test("SmartPlaylistError names the broken rule rather than a code")
    func smartPlaylistError() {
        let cases: [SmartPlaylistError] = [
            .emptyGroup,
            .betweenRangeReversed,
            .invalidRegex("["),
            .incompatibleComparator(field: .title, comparator: .greaterThan),
            .incompatibleValue(field: .title, value: .int(3)),
            .notFound(9),
            .notSmartPlaylist(9),
            .decodeFailed("bad json"),
            .tooDeeplyNested(maxDepth: 3),
            .cannotReferenceSmartPlaylist(id: 4),
            .invalidRule(reason: "unknown field"),
        ]
        for error in cases {
            #expect(error.errorDescription == error.description)
            #expect(error.localizedDescription == error.description)
            self.expectNoErrorCode(error.localizedDescription, "SmartPlaylistError")
        }

        // The field and comparator are named, not dumped as Swift case values.
        let mismatch = SmartPlaylistError.incompatibleComparator(field: .title, comparator: .greaterThan)
        #expect(mismatch.localizedDescription.contains(Field.title.rawValue))
        #expect(mismatch.localizedDescription.contains(Comparator.greaterThan.rawValue))
    }

    @Test("DeepDiveError carries its reason through localizedDescription")
    func deepDiveError() {
        let cases: [DeepDiveError] = [.noIdentifier, .offline, .rateLimited, .notFound]
        for error in cases {
            #expect(error.errorDescription == error.description)
            #expect(error.localizedDescription == error.description)
            self.expectNoErrorCode(error.localizedDescription, "DeepDiveError")
        }
    }
}
