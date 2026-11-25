import Foundation
import Testing
@testable import Library
@testable import Persistence

/// A playlist holds each song once. Adding one it already holds is skipped and
/// counted, so the UI can say so instead of doing nothing (#720).
@Suite("PlaylistService add skips songs already in the playlist (#720)")
struct PlaylistServiceAddSkipTests: PlaylistServiceFixtures {
    @Test("a song already in the playlist is skipped and counted")
    func skipsExistingSong() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let pid = try #require(try await service.create(name: "P").id)
        let first = try await self.makeTrack(in: db, fileURL: "file:///tmp/skip_a.mp3", title: "A")
        let second = try await self.makeTrack(in: db, fileURL: "file:///tmp/skip_b.mp3", title: "B")
        try await service.addTracks([first], to: pid)

        let result = try await service.addTracks([first, second], to: pid)

        #expect(result == PlaylistAddResult(added: 1, skipped: 1))
        #expect(try await service.tracks(in: pid).compactMap(\.id) == [first, second])
    }

    @Test("adding only songs the playlist holds changes nothing")
    func allPresentIsANoOp() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let pid = try #require(try await service.create(name: "P").id)
        let song = try await self.makeTrack(in: db, fileURL: "file:///tmp/skip_only.mp3", title: "Only")
        try await service.addTracks([song], to: pid)

        let result = try await service.addTracks([song], to: pid)

        #expect(result == PlaylistAddResult(added: 0, skipped: 1))
        #expect(try await service.tracks(in: pid).compactMap(\.id) == [song])
    }

    @Test("a song repeated within one add is written once")
    func repeatWithinBatch() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let pid = try #require(try await service.create(name: "P").id)
        let song = try await self.makeTrack(in: db, fileURL: "file:///tmp/skip_rep.mp3", title: "Rep")

        let result = try await service.addTracks([song, song], to: pid)

        #expect(result == PlaylistAddResult(added: 1, skipped: 1))
        #expect(try await service.tracks(in: pid).compactMap(\.id) == [song])
    }

    /// Positions 1 and 2 leave no gap, so an insert between them repacks the
    /// whole playlist. That path used to write the existing song a second
    /// time, which the unique index rejected, so the add failed outright.
    @Test("an add that repacks positions skips the existing song instead of failing")
    func repackPathSkips() async throws {
        let db = try await self.makeDatabase()
        let service = PlaylistService(database: db)
        let pid = try #require(try await service.create(name: "P").id)
        let first = try await self.makeTrack(in: db, fileURL: "file:///tmp/skip_r1.mp3", title: "R1")
        let second = try await self.makeTrack(in: db, fileURL: "file:///tmp/skip_r2.mp3", title: "R2")
        let third = try await self.makeTrack(in: db, fileURL: "file:///tmp/skip_r3.mp3", title: "R3")
        try await PlaylistRepository(database: db).replaceMembership(
            playlistID: pid,
            ordered: [(trackID: first, position: 1), (trackID: second, position: 2)]
        )

        let result = try await service.addTracks([first, third], to: pid, at: 1)

        #expect(result == PlaylistAddResult(added: 1, skipped: 1))
        #expect(try await service.tracks(in: pid).compactMap(\.id) == [first, third, second])
    }

    @Test("newMembers keeps order and drops existing and repeated ids")
    func newMembers() {
        #expect(PlaylistAddResult.newMembers([3, 1, 3, 2, 4], existing: [1, 2]) == [3, 4])
        #expect(PlaylistAddResult.newMembers([], existing: [1]).isEmpty)
        #expect(PlaylistAddResult.newMembers([5, 6], existing: []) == [5, 6])
    }
}
