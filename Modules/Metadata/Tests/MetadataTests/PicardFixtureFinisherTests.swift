import Foundation
import Testing
@testable import Metadata

/// One-off fixture finisher for `Scripts/gen-picard-fixtures.sh` (issue #420):
/// ffmpeg cannot write the freeform iTunes atoms TagLib reads, so the M4A's
/// MusicBrainz ids and RELEASETYPE are written with Bòcan's own `TagWriter`.
/// Skipped unless `BOCAN_FINISH_PICARD_FIXTURE=1`; the result is committed.
@Suite("Picard fixture finisher")
struct PicardFixtureFinisherTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOCAN_FINISH_PICARD_FIXTURE"] == "1"))
    func finishM4A() throws {
        // .../Modules/Metadata/Tests/MetadataTests/<file> up to .../Modules
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Library/Tests/LibraryTests/Fixtures/picard-library")
        let m4a = root.appendingPathComponent("A Quiet Storm/Harbour EP/02 - Lighthouse.m4a")
        var tags = try TagReader().read(from: m4a)
        tags.releaseType = "ep"
        tags.musicbrainzArtistID = "22222222-2222-4222-8222-222222222222"
        tags.musicbrainzAlbumArtistID = "22222222-2222-4222-8222-222222222222"
        tags.musicbrainzReleaseID = "bbbbbbb1-bbbb-4bbb-8bbb-bbbbbbbbbbb1"
        tags.musicbrainzReleaseGroupID = "bbbbbbb1-0000-4000-8000-000000000002"
        try TagWriter().write(tags, to: m4a)
        let reread = try TagReader().read(from: m4a)
        #expect(reread.musicbrainzArtistID == "22222222-2222-4222-8222-222222222222")
        #expect(reread.releaseType == "ep")
        #expect(reread.trackNumber == 2)
        #expect(reread.trackTotal == 2)
    }
}
