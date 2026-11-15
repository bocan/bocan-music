import Foundation
import Jellyfin
import Testing
@testable import UI

@Suite("Jellyfin browse view models")
@MainActor
struct JellyfinBrowseViewModelTests {
    private let server = UUID()

    // MARK: Songs

    @Test("Songs asks for the first page, then the next page from the number already loaded")
    func songsPaging() async {
        let source = StubBrowseSource()
        source.allSongs = jfSongs(250)
        let vm = JellyfinSongsViewModel(serverID: self.server, dataSource: source)
        await vm.load()
        #expect(vm.songs.count == 100)
        #expect(vm.hasMorePages)
        await vm.loadMore()
        await vm.loadMore()
        #expect(vm.songs.count == 250)
        #expect(!vm.hasMorePages, "a short last page ends the list")
        #expect(source.songStarts.value == [0, 100, 200])
        await vm.loadMore()
        #expect(source.songStarts.value.count == 3, "no request once the list has ended")
    }

    @Test("the server's total ends the list even when the last page is full")
    func songsTotalEndsTheList() async {
        let source = StubBrowseSource()
        source.allSongs = jfSongs(100)
        let vm = JellyfinSongsViewModel(serverID: self.server, dataSource: source)
        await vm.load()
        #expect(vm.songs.count == 100)
        #expect(!vm.hasMorePages, "100 of 100 is the whole list, so there is no page 2 to ask for")
    }

    @Test("a song that comes back twice shows once")
    func songsAreDeduplicated() async {
        let source = StubBrowseSource()
        source.allSongs = jfSongs(100)
        source.reportedTotal = 1000
        let vm = JellyfinSongsViewModel(serverID: self.server, dataSource: source)
        await vm.load()
        // The next page repeats the last song already loaded, as a library that changed between requests can.
        source.allSongs = jfSongs(100) + [jfSong("s99"), jfSong("s100")]
        await vm.loadMore()
        #expect(vm.songs.count == 101)
        #expect(Set(vm.songs.map(\.id)).count == vm.songs.count)
    }

    @Test("Random is one request, has no next page and keeps a cached selection instead of reshuffling")
    func randomKeepsCache() async {
        let source = StubBrowseSource()
        source.randomList = jfSongs(30, prefix: "r")
        let cache = MemoryCache()
        let first = JellyfinSongsViewModel(serverID: self.server, dataSource: source, cache: cache, source: .random)
        await first.load()
        #expect(first.songs.count == 30)
        #expect(!first.hasMorePages)
        #expect(source.randomCalls.value == 1)

        let second = JellyfinSongsViewModel(serverID: self.server, dataSource: source, cache: cache, source: .random)
        await second.load()
        #expect(second.songs.map(\.id) == first.songs.map(\.id))
        #expect(source.randomCalls.value == 1, "the cached selection is shown without a new draw")

        await second.refresh()
        #expect(source.randomCalls.value == 2, "Refresh draws again")
    }

    @Test("Most Played shows the server's order and is cached under its own key")
    func mostPlayed() async {
        let source = StubBrowseSource()
        source.mostPlayedList = [jfSong("a"), jfSong("b")]
        source.allSongs = [jfSong("z")]
        let cache = MemoryCache()
        let vm = JellyfinSongsViewModel(serverID: self.server, dataSource: source, cache: cache, source: .mostPlayed)
        await vm.load()
        #expect(vm.songs.map(\.id) == ["a", "b"])
        let all = JellyfinSongsViewModel(serverID: self.server, dataSource: source, cache: cache, source: .all)
        await all.load()
        #expect(all.songs.map(\.id) == ["z"], "Songs must not read the Most Played snapshot")
    }

    @Test("a failed load keeps what is shown and reports the reason")
    func songsFailure() async {
        let source = StubBrowseSource()
        source.failure = StubBrowseSource.Failure()
        let vm = JellyfinSongsViewModel(serverID: self.server, dataSource: source)
        await vm.load()
        #expect(vm.songs.isEmpty)
        #expect(vm.errorMessage == "stub failure")
        #expect(!vm.isLoading)
    }

    @Test("a snapshot that no longer decodes is ignored and the server is asked")
    func undecodableSnapshot() async {
        let source = StubBrowseSource()
        source.allSongs = [jfSong("fresh")]
        let cache = MemoryCache()
        cache.put(serverID: self.server, kind: "songs.firstPage", id: "all", data: Data("not json".utf8))
        let vm = JellyfinSongsViewModel(serverID: self.server, dataSource: source, cache: cache)
        await vm.load()
        #expect(vm.songs.map(\.id) == ["fresh"])
    }

    @Test("rows are built once per change, and a rename of the server rebuilds them")
    func rowsAndVersion() async {
        let source = StubBrowseSource()
        source.allSongs = jfSongs(3)
        let vm = JellyfinSongsViewModel(serverID: self.server, dataSource: source, serverName: "Basement")
        await vm.load()
        #expect(vm.rows.map(\.serverName) == ["Basement", "Basement", "Basement"])
        let version = vm.rowsVersion
        vm.serverName = "Basement"
        #expect(vm.rowsVersion == version, "the same name rebuilds nothing")
        vm.serverName = "Attic"
        #expect(vm.rowsVersion != version)
        #expect(vm.rows.allSatisfy { $0.serverName == "Attic" })
        #expect(vm.rows.map(\.id) == (0 ..< 3).map { "\(self.server.uuidString)::s\($0)" })
    }

    // MARK: Albums, artists, genres

    @Test("Albums page the same way, and a short page ends the list")
    func albumsPaging() async {
        let source = StubBrowseSource()
        source.allAlbums = (0 ..< 130).map { JellyfinAlbum(id: "a\($0)", title: "Album \($0)") }
        let vm = JellyfinAlbumsViewModel(serverID: self.server, dataSource: source)
        await vm.load()
        #expect(vm.albums.count == 100 && vm.hasMorePages)
        await vm.loadMore()
        #expect(vm.albums.count == 130 && !vm.hasMorePages)
        #expect(source.albumStarts.value == [0, 100])
    }

    @Test("Artists are grouped by initial with a # group last")
    func artistGroups() async {
        let source = StubBrowseSource()
        source.allArtists = [
            JellyfinArtist(id: "1", name: "Bjork"), JellyfinArtist(id: "2", name: "abba"),
            JellyfinArtist(id: "3", name: "50 Cent"), JellyfinArtist(id: "4", name: "Ash"),
            JellyfinArtist(id: "5", name: ""),
        ]
        let vm = JellyfinArtistsViewModel(serverID: self.server, dataSource: source)
        await vm.load()
        #expect(vm.sections.map(\.letter) == ["A", "B", "#"])
        #expect(vm.sections[0].artists.map(\.id) == ["2", "4"])
        #expect(vm.sections[2].artists.map(\.id) == ["3", "5"])
    }

    @Test("Genres loads every page and notes a genre with no count")
    func genresLoadEveryPage() async {
        let source = StubBrowseSource()
        source.allGenres = (0 ..< 3).map { JellyfinGenre(id: "g\($0)", name: "Genre \($0)", songCount: $0 == 0 ? nil : $0) }
        let vm = JellyfinGenresViewModel(serverID: self.server, dataSource: source)
        await vm.load()
        #expect(vm.genres.map(\.id) == ["g0", "g1", "g2"])
        #expect(vm.genres[0].songCount == nil, "a missing count stays nil and is not shown as 0")
    }

    @Test("the songs of a genre page by the genre's id")
    func genreSongs() async {
        let source = StubBrowseSource()
        source.genreSongs = jfSongs(120, prefix: "g")
        let model = JellyfinGenreSongsModel(serverID: self.server, genreID: "g1", dataSource: source)
        await model.loadMore()
        #expect(model.songs.count == 100 && model.hasMorePages)
        await model.loadMore()
        #expect(model.songs.count == 120 && !model.hasMorePages)
    }

    // MARK: Starred, playlists, details

    @Test("Starred shows the favourite songs and counts the albums and artists")
    func starred() async {
        let source = StubBrowseSource()
        source.starredResult = JellyfinSearchResult(
            songs: [jfSong("a")],
            albums: [JellyfinAlbum(id: "x", title: "X"), JellyfinAlbum(id: "y", title: "Y")],
            artists: [JellyfinArtist(id: "z", name: "Z")]
        )
        let vm = JellyfinStarredViewModel(serverID: self.server, dataSource: source)
        await vm.load()
        #expect(vm.songs.map(\.id) == ["a"])
        #expect(vm.albumCount == 2 && vm.artistCount == 1)
    }

    @Test("Playlists are sorted by name the way Finder sorts")
    func playlistsSorted() async {
        let source = StubBrowseSource()
        source.playlistList = [
            JellyfinPlaylist(id: "1", name: "Mix 10"), JellyfinPlaylist(id: "2", name: "Mix 2"),
            JellyfinPlaylist(id: "3", name: "Alpha"),
        ]
        let vm = JellyfinPlaylistsViewModel(serverID: self.server, dataSource: source)
        await vm.load()
        #expect(vm.playlists.map(\.name) == ["Alpha", "Mix 2", "Mix 10"])
    }

    @Test("a playlist that holds one song twice shows it once, because a table row needs a unique id")
    func playlistDetailDeduplicates() async {
        let source = StubBrowseSource()
        source.playlistContents = [jfSong("a"), jfSong("b"), jfSong("a")]
        let vm = JellyfinPlaylistDetailViewModel(serverID: self.server, playlistID: "p", dataSource: source)
        await vm.loadMore()
        #expect(vm.songs.map(\.id) == ["a", "b"])
        #expect(vm.hasLoaded)
    }

    @Test("an album page loads the album and its songs together")
    func albumDetail() async {
        let source = StubBrowseSource()
        source.albumByID["al"] = JellyfinAlbum(id: "al", title: "The Waves", year: 2012)
        source.songsByAlbum["al"] = [
            JellyfinSong(id: "s1", title: "One", durationSeconds: 100),
            JellyfinSong(id: "s2", title: "Two", durationSeconds: 80.5),
        ]
        let vm = JellyfinAlbumDetailViewModel(serverID: self.server, albumID: "al", dataSource: source)
        await vm.load()
        #expect(vm.album?.title == "The Waves")
        #expect(vm.songs.count == 2)
        #expect(vm.totalSeconds == 180)
    }

    @Test("an artist page loads the albums, then every album's songs in album, disc and track order")
    func artistDetail() async {
        let source = StubBrowseSource()
        source.artistByID["ar"] = JellyfinArtist(id: "ar", name: "Artist")
        source.albumsByArtist["ar"] = [JellyfinAlbum(id: "b", title: "B"), JellyfinAlbum(id: "a", title: "A")]
        source.songsByAlbum["a"] = [jfSong("a2", album: "A", disc: 1, track: 2), jfSong("a1", album: "A", disc: 1, track: 1)]
        source.songsByAlbum["b"] = [jfSong("b2", album: "B", disc: 2, track: 1), jfSong("b1", album: "B", disc: 1, track: 5)]
        let vm = JellyfinArtistDetailViewModel(serverID: self.server, artistID: "ar", dataSource: source)
        await vm.load()
        #expect(vm.albums.count == 2)
        #expect(await waitUntil { vm.songs.count == 4 })
        #expect(vm.songs.map(\.id) == ["a1", "a2", "b1", "b2"])
    }

    @Test("a missing album leaves the page empty and says nothing broke")
    func albumMissing() async {
        let vm = JellyfinAlbumDetailViewModel(serverID: self.server, albumID: "none", dataSource: StubBrowseSource())
        await vm.load()
        #expect(vm.album == nil)
        #expect(vm.errorMessage == nil)
    }

    @Test("the placeholder data source throws, so nothing partial ever shows")
    func noopSource() async {
        let vm = JellyfinSongsViewModel(serverID: self.server, dataSource: NoopJellyfinBrowseDataSource())
        await vm.load()
        #expect(vm.songs.isEmpty)
        #expect(vm.errorMessage != nil)
    }
}
