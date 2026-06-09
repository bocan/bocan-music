import Testing
@testable import UI

// MARK: - RemoveFromLibraryConfirmTests

/// Regression coverage for issue #258: album/artist "Remove from Library" now
/// routes through a confirmation. The prompt wording is built by pure helpers,
/// exercised here; the NSAlert presentation itself is UI and is not unit-tested,
/// matching the existing per-track confirmation.
@Suite("RemoveFromLibraryConfirm message text")
struct RemoveFromLibraryConfirmTests {
    @Test("a single album names its title")
    func singleAlbumNamesTitle() {
        #expect(
            RemoveFromLibraryConfirm.albumsMessage(count: 1, soleTitle: "Kind of Blue")
                == "Remove “Kind of Blue” from library?"
        )
    }

    @Test("a single album with no known title falls back to a count")
    func singleAlbumNoTitle() {
        // The singular wording ("1 album") is a catalog plural rule, asserted in
        // L10nTests; only Xcode builds compile plural variations, so this stays
        // harness-independent (#314).
        let message = RemoveFromLibraryConfirm.albumsMessage(count: 1, soleTitle: nil)
        #expect(message.hasPrefix("Remove 1 album"))
        #expect(message.hasSuffix("from library?"))
    }

    @Test("multiple albums use a pluralised count and ignore any title")
    func multipleAlbumsPluralise() {
        #expect(
            RemoveFromLibraryConfirm.albumsMessage(count: 12, soleTitle: "ignored")
                == "Remove 12 albums from library?"
        )
    }

    @Test("the artist prompt names the artist")
    func artistNamed() {
        #expect(
            RemoveFromLibraryConfirm.artistMessage(name: "Miles Davis")
                == "Remove all music by “Miles Davis” from library?"
        )
    }

    @Test("the artist prompt falls back when the name is missing or empty", arguments: [nil, ""])
    func artistFallback(name: String?) {
        #expect(RemoveFromLibraryConfirm.artistMessage(name: name) == "Remove this artist from library?")
    }
}
