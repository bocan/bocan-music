import Foundation
import Testing
@testable import Persistence

/// Re-linking a hidden track to a file at a new path (#647).
@Suite("TrackRepository relink")
struct TrackRepositoryRelinkTests {
    private func makeTrack(_ fileURL: String, size: Int64 = 1024, disabled: Bool = true) -> Track {
        Track(
            fileURL: fileURL,
            fileBookmark: Data([0x01]),
            fileSize: size,
            fileMtime: 1_700_000_000,
            fileFormat: "flac",
            duration: 180,
            title: "T",
            rating: 80,
            disabled: disabled,
            addedAt: 1_700_000_000,
            updatedAt: 1_700_000_000
        )
    }

    @Test("only hidden tracks are candidates, and the size filter narrows them")
    func candidatesAreHiddenTracks() async throws {
        let repo = try await TrackRepository(database: Database(location: .inMemory))
        let hidden = try await repo.insert(self.makeTrack("file:///old/a.flac"))
        let other = try await repo.insert(self.makeTrack("file:///old/b.flac", size: 2048))
        _ = try await repo.insert(self.makeTrack("file:///old/c.flac", disabled: false))
        try await repo.setContentHash(trackID: hidden, hash: "abc")

        let all = try await repo.hiddenTrackCandidates()
        let sized = try await repo.hiddenTrackCandidates(fileSize: 1024)

        #expect(all.map(\.id) == [hidden, other])
        let expected = HiddenTrackCandidate(
            id: hidden,
            fileURL: "file:///old/a.flac",
            fileSize: 1024,
            fileMtime: 1_700_000_000,
            contentHash: "abc"
        )
        #expect(sized == [expected])
    }

    @Test("a re-link moves the row to the new path, shows it, and keeps the listener's state")
    func relinkKeepsTheRow() async throws {
        let repo = try await TrackRepository(database: Database(location: .inMemory))
        let id = try await repo.insert(self.makeTrack("file:///old/a.flac"))

        let done = try await repo.relinkHiddenTrack(
            id: id,
            toFileURL: "file:///new%20drive/a.flac",
            pathDisplay: "/new drive/a.flac",
            fileMtime: 1_800_000_000
        )

        let track = try await repo.fetch(id: id)
        #expect(done)
        #expect(track.fileURL == "file:///new%20drive/a.flac")
        #expect(track.filePathDisplay == "/new drive/a.flac")
        #expect(track.fileMtime == 1_800_000_000)
        #expect(!track.disabled)
        #expect(track.fileBookmark == nil, "the old bookmark names the old place")
        #expect(track.rating == 80)
    }

    @Test("a visible track is never re-linked")
    func visibleTrackIsLeftAlone() async throws {
        let repo = try await TrackRepository(database: Database(location: .inMemory))
        let id = try await repo.insert(self.makeTrack("file:///old/a.flac", disabled: false))

        let done = try await repo.relinkHiddenTrack(
            id: id,
            toFileURL: "file:///new/a.flac",
            pathDisplay: "/new/a.flac",
            fileMtime: 1
        )

        #expect(!done)
        #expect(try await repo.fetch(id: id).fileURL == "file:///old/a.flac")
    }
}
