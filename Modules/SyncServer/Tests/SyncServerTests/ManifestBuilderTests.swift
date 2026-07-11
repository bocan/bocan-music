import Foundation
import Persistence
import Testing
@testable import SyncServer

@Suite("ManifestBuilder")
struct ManifestBuilderTests {
    private struct Fixture {
        let builder: ManifestBuilder
        let tracks: TrackRepository
        let artists: ArtistRepository
        let albums: AlbumRepository
        let playlists: PlaylistRepository
        let roots: LibraryRootRepository
        let lyrics: LyricsRepository
    }

    private func makeFixture() async throws -> Fixture {
        let database = try await Database(location: .inMemory)
        return Fixture(
            builder: ManifestBuilder(database: database),
            tracks: TrackRepository(database: database),
            artists: ArtistRepository(database: database),
            albums: AlbumRepository(database: database),
            playlists: PlaylistRepository(database: database),
            roots: LibraryRootRepository(database: database),
            lyrics: LyricsRepository(database: database)
        )
    }

    private func seedRoot(_ fixture: Fixture, path: String = "/Music") async throws {
        _ = try await fixture.roots.upsert(LibraryRoot(path: path, bookmark: Data([0x01]), addedAt: 0))
    }

    private func fileURL(_ posixPath: String) -> String {
        URL(fileURLWithPath: posixPath).absoluteString
    }

    private func build(
        _ fixture: Fixture,
        profile: SyncProfile = .everything(includePodcasts: true)
    ) async throws -> Manifest {
        try await fixture.builder.build(
            profile: profile,
            serverId: "srv",
            serverName: "Mac",
            generation: 1,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("derives relPath and resolves artist and album names")
    func relPathAndNames() async throws {
        let fixture = try await self.makeFixture()
        try await self.seedRoot(fixture)
        let artistId = try await fixture.artists.insert(Artist(name: "My Bloody Valentine"))
        let albumId = try await fixture.albums.insert(Album(title: "Loveless", albumArtistID: artistId))
        _ = try await fixture.tracks.insert(Track(
            fileURL: self.fileURL("/Music/My Bloody Valentine/Loveless/01 Only Shallow.flac"),
            fileSize: 31_337_000,
            fileFormat: "flac",
            duration: 254,
            title: "Only Shallow",
            artistID: artistId,
            albumArtistID: artistId,
            albumID: albumId,
            rating: 80,
            loved: true,
            contentHash: "aa01",
            addedAt: 0,
            updatedAt: 0
        ))

        let track = try #require(try await self.build(fixture).tracks.first)
        #expect(track.relPath == "My Bloody Valentine/Loveless/01 Only Shallow.flac")
        #expect(track.artist == "My Bloody Valentine")
        #expect(track.albumArtist == "My Bloody Valentine")
        #expect(track.album == "Loveless")
        #expect(track.durationMs == 254_000)
        #expect(track.sha256 == "aa01")
        #expect(track.rating == 80)
        #expect(track.loved)
    }

    @Test("a track with no content hash is excluded")
    func nullHashExcluded() async throws {
        let fixture = try await self.makeFixture()
        try await self.seedRoot(fixture)
        _ = try await fixture.tracks.insert(Track(fileURL: self.fileURL("/Music/x.flac"), contentHash: nil, addedAt: 0, updatedAt: 0))
        #expect(try await self.build(fixture).tracks.isEmpty)
    }

    @Test("a track under no library root is excluded")
    func outsideRootsExcluded() async throws {
        let fixture = try await self.makeFixture()
        try await self.seedRoot(fixture, path: "/Music")
        _ = try await fixture.tracks.insert(Track(
            fileURL: self.fileURL("/Other/y.flac"),
            fileFormat: "flac",
            contentHash: "bb",
            addedAt: 0,
            updatedAt: 0
        ))
        #expect(try await self.build(fixture).tracks.isEmpty)
    }

    @Test("a CUE clip resolves its parent and duplicates its file identity")
    func clipResolution() async throws {
        let fixture = try await self.makeFixture()
        try await self.seedRoot(fixture)
        let sourceURL = self.fileURL("/Music/Album/full.mp3")
        let sourceId = try await fixture.tracks.insert(Track(
            fileURL: sourceURL, fileSize: 9_200_000, fileFormat: "mp3", duration: 356,
            title: "Full", contentHash: "aa03", addedAt: 0, updatedAt: 0
        ))
        _ = try await fixture.tracks.insert(Track(
            fileURL: self.fileURL("/Music/Album/full.mp3#clip"), fileFormat: "mp3", duration: 60,
            title: "Intro", contentHash: "ignored",
            startOffsetMs: 0, endOffsetMs: 60000, sourceFileURL: sourceURL, addedAt: 0, updatedAt: 0
        ))

        let manifest = try await self.build(fixture)
        let clip = try #require(manifest.tracks.first { $0.clip != nil })
        #expect(clip.clip == ManifestClip(sourceTrackId: sourceId, startMs: 0, endMs: 60000))
        #expect(clip.sha256 == "aa03") // source's
        #expect(clip.size == 9_200_000) // source's
        #expect(clip.relPath == "Album/full.mp3") // source's
        #expect(clip.durationMs == 60000) // the clip's own duration
        #expect(clip.title == "Intro") // the clip's own metadata
    }

    @Test("replay gain is emitted only when a track gain is present")
    func replayGainNullability() async throws {
        let fixture = try await self.makeFixture()
        try await self.seedRoot(fixture)
        _ = try await fixture.tracks.insert(Track(
            fileURL: self.fileURL("/Music/a.flac"), fileFormat: "flac",
            replaygainTrackGain: -6.2, replaygainTrackPeak: 0.91, contentHash: "aa", addedAt: 0, updatedAt: 0
        ))
        _ = try await fixture.tracks.insert(Track(
            fileURL: self.fileURL("/Music/b.flac"),
            fileFormat: "flac",
            contentHash: "bb",
            addedAt: 0,
            updatedAt: 0
        ))

        let manifest = try await self.build(fixture)
        let withGain = try #require(manifest.tracks.first { $0.sha256 == "aa" })
        let without = try #require(manifest.tracks.first { $0.sha256 == "bb" })
        #expect(withGain.replayGain == ManifestReplayGain(trackGain: -6.2, trackPeak: 0.91, albumGain: nil, albumPeak: nil))
        #expect(without.replayGain == nil)
    }

    @Test("lyricsHash is computed when lyrics exist and nil otherwise")
    func lyricsHashComputed() async throws {
        let fixture = try await self.makeFixture()
        try await self.seedRoot(fixture)
        let withLyrics = try await fixture.tracks.insert(Track(
            fileURL: self.fileURL("/Music/l.flac"),
            fileFormat: "flac",
            contentHash: "aa",
            addedAt: 0,
            updatedAt: 0
        ))
        _ = try await fixture.tracks.insert(Track(
            fileURL: self.fileURL("/Music/n.flac"),
            fileFormat: "flac",
            contentHash: "bb",
            addedAt: 0,
            updatedAt: 0
        ))
        try await fixture.lyrics.save(Lyrics(trackID: withLyrics, lyricsText: "[00:12.00]Hello", isSynced: true, source: "user"))

        let manifest = try await self.build(fixture)
        let lyric = try #require(manifest.tracks.first { $0.sha256 == "aa" })
        let none = try #require(manifest.tracks.first { $0.sha256 == "bb" })
        #expect(lyric.lyricsHash?.count == 64)
        #expect(none.lyricsHash == nil)
    }

    @Test("playlists map kind, membership order, and folder emptiness")
    func playlistMapping() async throws {
        let fixture = try await self.makeFixture()
        try await self.seedRoot(fixture)
        let first = try await fixture.tracks.insert(Track(
            fileURL: self.fileURL("/Music/1.flac"),
            fileFormat: "flac",
            contentHash: "a1",
            addedAt: 0,
            updatedAt: 0
        ))
        let second = try await fixture.tracks.insert(Track(
            fileURL: self.fileURL("/Music/2.flac"),
            fileFormat: "flac",
            contentHash: "a2",
            addedAt: 0,
            updatedAt: 0
        ))

        let folderId = try await fixture.playlists.insert(Playlist(name: "Moods", sortOrder: 1, createdAt: 0, updatedAt: 0, kind: .folder))
        let manualId = try await fixture.playlists.insert(Playlist(
            name: "Late Night", sortOrder: 2, createdAt: 0, updatedAt: 0,
            parentID: folderId, kind: .manual, accentColor: "#A259FF"
        ))
        try await fixture.playlists.insertRows(
            [PlaylistTrack(playlistID: manualId, trackID: second, position: 0),
             PlaylistTrack(playlistID: manualId, trackID: first, position: 1)],
            in: manualId
        )

        let manifest = try await self.build(fixture)
        let folder = try #require(manifest.playlists.first { $0.id == folderId })
        #expect(folder.kind == "folder")
        #expect(folder.trackIds.isEmpty)
        let manual = try #require(manifest.playlists.first { $0.id == manualId })
        #expect(manual.kind == "manual")
        #expect(manual.parentId == folderId)
        #expect(manual.accentColor == "#A259FF")
        #expect(manual.trackIds == [second, first])
    }

    @Test("a selected profile includes only the chosen playlist's tracks")
    func selectedProfile() async throws {
        let fixture = try await self.makeFixture()
        try await self.seedRoot(fixture)
        let included = try await fixture.tracks.insert(Track(
            fileURL: self.fileURL("/Music/in.flac"),
            fileFormat: "flac",
            contentHash: "a1",
            addedAt: 0,
            updatedAt: 0
        ))
        _ = try await fixture.tracks.insert(Track(
            fileURL: self.fileURL("/Music/out.flac"),
            fileFormat: "flac",
            contentHash: "a2",
            addedAt: 0,
            updatedAt: 0
        ))
        let playlistId = try await fixture.playlists.insert(Playlist(name: "P", sortOrder: 1, createdAt: 0, updatedAt: 0, kind: .manual))
        try await fixture.playlists.insertRows([PlaylistTrack(playlistID: playlistId, trackID: included, position: 0)], in: playlistId)

        let manifest = try await self.build(fixture, profile: .selected(playlistIds: [playlistId], includePodcasts: false))
        #expect(manifest.tracks.map(\.sha256) == ["a1"])
    }
}
