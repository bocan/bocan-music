import Foundation
import Persistence
import Testing
@testable import UI

/// Covers `TrackRow.hasSameContent(as:)`, the content-equality check that lets
/// `TrackTable` reconfigure a row in place when its displayed values change
/// (a play-count bump, a love toggle) even though its identity is unchanged.
@MainActor
@Suite("TrackRow content equality")
struct TrackRowContentTests {
    private func makeTrack(
        id: Int64,
        playCount: Int = 0,
        loved: Bool = false,
        rating: Int = 0,
        title: String = "Song"
    ) -> Track {
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            id: id,
            fileURL: "file:///Music/\(id).flac",
            fileSize: 0,
            fileMtime: now,
            fileFormat: "flac",
            duration: 100,
            title: title,
            addedAt: now,
            updatedAt: now
        )
        track.playCount = playCount
        track.loved = loved
        track.rating = rating
        return track
    }

    @Test("identical rows have identical content")
    func identicalRowsMatch() {
        let lhs = TrackRow(track: self.makeTrack(id: 1), artistName: "A", albumName: "B")
        let rhs = TrackRow(track: self.makeTrack(id: 1), artistName: "A", albumName: "B")
        #expect(lhs.hasSameContent(as: rhs))
    }

    @Test("a play-count bump is a content change but not an identity change")
    func playCountChangeDiffers() {
        let before = TrackRow(track: self.makeTrack(id: 1, playCount: 3), artistName: "A", albumName: "B")
        let after = TrackRow(track: self.makeTrack(id: 1, playCount: 4), artistName: "A", albumName: "B")
        // Same DB row -> equal identity, so the diffable snapshot keeps it stable...
        #expect(before == after)
        // ...but the rendered content differs, so the cell must be reconfigured.
        #expect(!before.hasSameContent(as: after))
    }

    @Test("a love toggle is a content change")
    func lovedChangeDiffers() {
        let before = TrackRow(track: self.makeTrack(id: 1, loved: false), artistName: "A", albumName: "B")
        let after = TrackRow(track: self.makeTrack(id: 1, loved: true), artistName: "A", albumName: "B")
        #expect(!before.hasSameContent(as: after))
    }

    @Test("a decorated artist-name change is a content change")
    func artistNameChangeDiffers() {
        let before = TrackRow(track: self.makeTrack(id: 1), artistName: "Old", albumName: "B")
        let after = TrackRow(track: self.makeTrack(id: 1), artistName: "New", albumName: "B")
        #expect(!before.hasSameContent(as: after))
    }
}
