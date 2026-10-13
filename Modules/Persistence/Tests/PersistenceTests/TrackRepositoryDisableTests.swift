import Foundation
import Testing
@testable import Persistence

/// The bulk soft-deletes behind folder removal (#643).
@Suite("TrackRepository bulk disable")
struct TrackRepositoryDisableTests {
    private func makeTrack(_ fileURL: String, albumID: Int64? = nil, artistID: Int64? = nil) -> Track {
        Track(
            fileURL: fileURL,
            fileSize: 1024,
            fileMtime: 1_700_000_000,
            fileFormat: "flac",
            duration: 180,
            title: "T",
            artistID: artistID,
            albumID: albumID,
            addedAt: 1_700_000_000,
            updatedAt: 1_700_000_000
        )
    }

    private func isDisabled(_ id: Int64, in repo: TrackRepository) async throws -> Bool {
        try await repo.fetch(id: id).disabled
    }

    // MARK: - disableAll(underDirectoryURL:)

    @Test("matches the stored file:// form, percent-encoding included")
    func matchesStoredURLForm() async throws {
        let repo = try await TrackRepository(database: Database(location: .inMemory))
        let inside = try await repo.insert(self.makeTrack("file:///Volumes/external%20volume/Music/a/1.flac"))
        let sibling = try await repo.insert(self.makeTrack("file:///Volumes/external%20volume/Music2/1.flac"))

        let count = try await repo.disableAll(underDirectoryURL: "file:///Volumes/external%20volume/Music")

        #expect(count == 1)
        #expect(try await self.isDisabled(inside, in: repo))
        #expect(try await !self.isDisabled(sibling, in: repo), "whole path components: Music does not hold Music2")
    }

    @Test("a plain path matches nothing, which is the #643 defect")
    func plainPathMatchesNothing() async throws {
        let repo = try await TrackRepository(database: Database(location: .inMemory))
        let id = try await repo.insert(self.makeTrack("file:///Volumes/x/Music/1.flac"))

        let count = try await repo.disableAll(underDirectoryURL: "/Volumes/x/Music")

        #expect(count == 0)
        #expect(try await !self.isDisabled(id, in: repo))
    }

    @Test("an underscore or percent sign in the folder name is literal, not a wildcard")
    func wildcardCharactersAreLiteral() async throws {
        let repo = try await TrackRepository(database: Database(location: .inMemory))
        let inside = try await repo.insert(self.makeTrack("file:///m/a_b/1.flac"))
        let lookalike = try await repo.insert(self.makeTrack("file:///m/aXb/1.flac"))

        let count = try await repo.disableAll(underDirectoryURL: "file:///m/a_b/")

        #expect(count == 1)
        #expect(try await self.isDisabled(inside, in: repo))
        #expect(try await !self.isDisabled(lookalike, in: repo))
    }

    // MARK: - enabledFileURLs / disable(ids:)

    @Test("enabledFileURLs leaves out disabled tracks")
    func enabledFileURLsSkipsDisabled() async throws {
        let repo = try await TrackRepository(database: Database(location: .inMemory))
        let kept = try await repo.insert(self.makeTrack("file:///m/1.flac"))
        let gone = try await repo.insert(self.makeTrack("file:///m/2.flac"))
        try await repo.disable(id: gone)

        #expect(try await repo.enabledFileURLs() == [kept: "file:///m/1.flac"])
    }

    @Test("disable(ids:) hides exactly the listed tracks, across more than one chunk")
    func disableIDs() async throws {
        let repo = try await TrackRepository(database: Database(location: .inMemory))
        var ids: [Int64] = []
        for index in 0 ..< 620 {
            try await ids.append(repo.insert(self.makeTrack("file:///m/\(index).flac")))
        }
        let untouched = ids.removeLast()

        let count = try await repo.disable(ids: ids)

        #expect(count == 619)
        #expect(try await repo.enabledFileURLs().keys.sorted() == [untouched])
        #expect(try await repo.disable(ids: ids) == 0, "already hidden rows do not count twice")
        #expect(try await repo.disable(ids: []) == 0)
    }

    // MARK: - pruneAlbumsAndArtistsWithoutEnabledTracks

    @Test("prune deletes albums and artists with no enabled track and keeps the rest")
    func pruneKeepsWhatIsInUse() async throws {
        let db = try await Database(location: .inMemory)
        let repo = TrackRepository(database: db)
        let artists = ArtistRepository(database: db)
        let albums = AlbumRepository(database: db)
        let keptArtist = try #require(try await artists.findOrCreate(name: "Kept").id)
        let goneArtist = try #require(try await artists.findOrCreate(name: "Gone").id)
        let keptAlbum = try #require(try await albums.findOrCreate(title: "Kept", albumArtistID: keptArtist).id)
        let goneAlbum = try #require(try await albums.findOrCreate(title: "Gone", albumArtistID: nil).id)
        _ = try await repo.insert(self.makeTrack("file:///m/k.flac", albumID: keptAlbum, artistID: keptArtist))
        let hidden = try await repo.insert(self.makeTrack("file:///m/g.flac", albumID: goneAlbum, artistID: goneArtist))
        try await repo.disable(ids: [hidden])

        let pruned = try await repo.pruneAlbumsAndArtistsWithoutEnabledTracks()

        #expect(pruned.albums == 1)
        #expect(pruned.artists == 1)
        #expect(try await albums.fetchAll().map(\.title) == ["Kept"])
        #expect(try await artists.fetchAll().map(\.name) == ["Kept"])
    }
}
