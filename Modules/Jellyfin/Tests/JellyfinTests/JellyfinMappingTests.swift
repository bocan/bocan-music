import Foundation
import Get
import JellyfinAPI
import Testing
@testable import Jellyfin

@Suite("JellyfinMapping")
struct JellyfinMappingTests {
    // MARK: Ticks

    @Test("ticks convert to seconds and back")
    func ticks() {
        #expect(JellyfinMapping.seconds(fromTicks: 2_405_000_000) == 240.5)
        #expect(JellyfinMapping.seconds(fromTicks: nil) == nil)
        #expect(JellyfinMapping.ticks(fromSeconds: 240.5) == 2_405_000_000)
        #expect(JellyfinMapping.ticks(fromSeconds: -3) == 0)
        #expect(JellyfinMapping.ticks(fromSeconds: .nan) == 0)
        #expect(JellyfinMapping.ticks(fromSeconds: .infinity) == 0)
    }

    @Test("a day of audio does not overflow the tick count")
    func largeTicks() {
        #expect(JellyfinMapping.ticks(fromSeconds: 86400) == 864_000_000_000)
    }

    // MARK: Songs

    @Test("a full song maps every field, and the cover comes from the album")
    func fullSong() throws {
        let result = try Fixture.decode(BaseItemDtoQueryResult.self, "songs")
        let page = JellyfinMapping.page(result, JellyfinMapping.song)
        let song = try #require(page.items.first)
        #expect(song.id == "3f9c0d2e8b7a4c1d9e5f6a7b8c9d0e1f")
        #expect(song.title == "Prayer in C")
        #expect(song.artistName == "Lilly Wood and The Prick")
        #expect(song.artistID == "aa11bb22cc33dd44ee55ff6677889900")
        #expect(song.albumTitle == "The Waves")
        #expect(song.albumID == "9d8c7b6a5f4e3d2c1b0a998877665544")
        #expect(song.trackNumber == 7)
        #expect(song.discNumber == 2)
        #expect(song.year == 2012)
        #expect(song.genre == "Folk")
        #expect(song.durationSeconds == 240.5)
        #expect(song.bitrateKbps == 960)
        #expect(song.container == "flac")
        #expect(song.isStarred)
        // The song has no image of its own, so the album owns the cover.
        #expect(song.coverArtID == "9d8c7b6a5f4e3d2c1b0a998877665544")
        #expect(song.coverArtTag == "c0ffee00c0ffee00c0ffee00c0ffee00")
    }

    @Test("a sparse song keeps every missing field nil and invents nothing")
    func sparseSong() throws {
        let result = try Fixture.decode(BaseItemDtoQueryResult.self, "songs")
        let song = try #require(JellyfinMapping.page(result, JellyfinMapping.song).items.dropFirst().first)
        #expect(song.id == "11112222333344445555666677778888")
        #expect(song.artistName == nil)
        #expect(song.albumTitle == nil)
        #expect(song.trackNumber == nil)
        #expect(song.year == nil)
        #expect(song.genre == nil)
        #expect(song.durationSeconds == nil)
        #expect(song.bitrateKbps == nil)
        #expect(song.container == "mp3")
        #expect(song.isStarred == false)
        // The song's own image wins over any album image.
        #expect(song.coverArtID == "11112222333344445555666677778888")
        #expect(song.coverArtTag == "deadbeefdeadbeefdeadbeefdeadbeef")
    }

    @Test("a song falls back to the parent image, then to the album artist for its name")
    func parentCoverAndArtistFallback() throws {
        let result = try Fixture.decode(BaseItemDtoQueryResult.self, "songs")
        let single = try #require(JellyfinMapping.page(result, JellyfinMapping.song).items.last)
        #expect(single.id == "99998888777766665555444433332222")
        #expect(single.artistName == "Solo Artist")
        #expect(single.coverArtID == "abcdefabcdefabcdefabcdefabcdefab")
        #expect(single.coverArtTag == "0123456789abcdef0123456789abcdef")
    }

    @Test("an item with no id is dropped and the server total is kept")
    func pageDropsIdLessRows() throws {
        let result = try Fixture.decode(BaseItemDtoQueryResult.self, "songs")
        let page = JellyfinMapping.page(result, JellyfinMapping.song)
        #expect(result.items?.count == 4)
        #expect(page.items.count == 3)
        #expect(page.total == 412)
    }

    @Test("a song with no cover anywhere has no cover id")
    func noCover() {
        let item = BaseItemDto(id: "x", name: "No art")
        let song = JellyfinMapping.song(item)
        #expect(song?.coverArtID == nil)
        #expect(song?.coverArtTag == nil)
    }

    @Test("ids are copied as sent: no case change and no dash handling")
    func idsAreOpaque() {
        let item = BaseItemDto(albumID: "ABCD-ef01", id: "3F9C0D2E-8B7A-4C1D-9E5F-6A7B8C9D0E1F", name: "x")
        let song = JellyfinMapping.song(item)
        #expect(song?.id == "3F9C0D2E-8B7A-4C1D-9E5F-6A7B8C9D0E1F")
        #expect(song?.albumID == "ABCD-ef01")
    }

    // MARK: Albums, artists, genres, playlists

    @Test("album mapping")
    func albums() throws {
        let result = try Fixture.decode(BaseItemDtoQueryResult.self, "albums")
        let page = JellyfinMapping.page(result, JellyfinMapping.album)
        let album = try #require(page.items.first)
        #expect(album.title == "The Waves")
        #expect(album.artistName == "Lilly Wood and The Prick")
        #expect(album.artistID == "aa11bb22cc33dd44ee55ff6677889900")
        #expect(album.year == 2012)
        #expect(album.genre == "Folk")
        #expect(album.songCount == 12)
        #expect(album.durationSeconds == 2163)
        #expect(album.isStarred)
        #expect(album.coverArtID == "9d8c7b6a5f4e3d2c1b0a998877665544")
        let bare = try #require(page.items.last)
        #expect(bare.year == nil)
        #expect(bare.artistName == nil)
        #expect(bare.songCount == nil)
        #expect(bare.coverArtID == nil)
    }

    @Test("artist mapping")
    func artists() throws {
        let result = try Fixture.decode(BaseItemDtoQueryResult.self, "artists")
        let artist = try #require(JellyfinMapping.page(result, JellyfinMapping.artist).items.first)
        #expect(artist.name == "Lilly Wood and The Prick")
        #expect(artist.albumCount == 3)
        #expect(artist.coverArtTag == "feedfacefeedfacefeedfacefeedface")
        #expect(artist.isStarred == false)
    }

    @Test("genre mapping drops a genre with no name")
    func genres() throws {
        let result = try Fixture.decode(BaseItemDtoQueryResult.self, "genres")
        let page = JellyfinMapping.page(result, JellyfinMapping.genre)
        #expect(page.items.map(\.name) == ["Folk", "A genre with no counts"])
        #expect(page.items[0].songCount == 180)
        #expect(page.items[0].albumCount == 14)
        #expect(page.items[1].songCount == nil)
    }

    @Test("playlist mapping")
    func playlists() throws {
        let result = try Fixture.decode(BaseItemDtoQueryResult.self, "playlists")
        let page = JellyfinMapping.page(result, JellyfinMapping.playlist)
        let playlist = try #require(page.items.first)
        #expect(playlist.name == "Road trip")
        #expect(playlist.songCount == 25)
        #expect(playlist.durationSeconds == 5400)
        #expect(playlist.coverArtTag == "abababababababababababababababab")
    }

    @Test("an audio playlist reported as Unknown is kept and a video playlist is dropped")
    func playlistMediaTypes() throws {
        // A real Jellyfin 12.2 server reports `Unknown` for audio playlists imported from an M3U file.
        let result = try Fixture.decode(BaseItemDtoQueryResult.self, "playlists")
        let page = JellyfinMapping.page(result, JellyfinMapping.playlist)
        #expect(page.items.map(\.name) == ["Road trip", "Imported from an M3U file"])
        #expect(page.items[1].coverArtID == nil)
        // The server's own total is kept, since the drop happens after paging.
        #expect(page.total == 3)
    }

    @Test("server info mapping")
    func serverInfo() throws {
        let info = try Fixture.decode(PublicSystemInfo.self, "public-info")
        let mapped = JellyfinMapping.serverInfo(info)
        #expect(mapped.serverName == "Basement")
        #expect(mapped.version == "10.10.7")
        #expect(mapped.serverID == "0a1b2c3d4e5f60718293a4b5c6d7e8f9")
    }

    // MARK: Errors

    @Test("a transport failure becomes a network error with no URL in it")
    func transportError() {
        let url = "https://jf.example.test/Audio/abc/stream?ApiKey=SECRETTOKEN"
        let urlError = URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: url])
        let mapped = JellyfinMapping.error(from: urlError)
        #expect(mapped == .network("the request timed out"))
        #expect(!String(reflecting: mapped).contains("SECRETTOKEN"))
        #expect(!(mapped.errorDescription ?? "").contains("SECRETTOKEN"))
    }

    @Test("HTTP 401 becomes unauthorized and other statuses keep their code")
    func httpStatusError() {
        #expect(JellyfinMapping.error(from: APIError.unacceptableStatusCode(401)) == .unauthorized)
        #expect(JellyfinMapping.error(from: APIError.unacceptableStatusCode(503)) == .http(status: 503))
        #expect(JellyfinMapping.error(from: APIError.unacceptableStatusCode(404)) == .http(status: 404))
    }

    @Test("a missing token and a decoding failure have their own cases")
    func otherErrors() {
        #expect(JellyfinMapping.error(from: JellyfinClient.ClientError.noAccessToken) == .noAccessToken)
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        if case .decoding = JellyfinMapping.error(from: decoding) {} else {
            Issue.record("expected .decoding")
        }
    }

    @Test("an error already mapped is passed through")
    func passthrough() {
        #expect(JellyfinMapping.error(from: JellyfinError.quickConnectDisabled) == .quickConnectDisabled)
    }

    @Test("error classification helpers")
    func classification() {
        #expect(JellyfinError.unauthorized.isAuthenticationFailure)
        #expect(JellyfinError.http(status: 401).isAuthenticationFailure)
        #expect(!JellyfinError.http(status: 500).isAuthenticationFailure)
        #expect(JellyfinError.http(status: 503).isTransient)
        #expect(JellyfinError.network("x").isTransient)
        #expect(!JellyfinError.unauthorized.isTransient)
        #expect(JellyfinError.keychain(-25300, "read").isCredentialMissing)
        #expect(!JellyfinError.keychain(-1, "read").isCredentialMissing)
    }
}
