import AppKit
import Foundation
import Jellyfin
import Testing
@testable import UI

@Suite("Jellyfin search")
@MainActor
struct JellyfinSearchTests {
    private func server(_ name: String, search: Bool = true) -> JellyfinSidebarServer {
        JellyfinSidebarServer(id: UUID(), name: name, sortIndex: 0, includeInGlobalSearch: search)
    }

    /// A search whose deadline never arrives, so it ends when every server has
    /// answered. The real deadline is a race against a server's answer, and a
    /// busy machine can make a stub that answers at once lose it.
    private func patientSearch(_ source: StubBrowseSource) -> JellyfinMultiSourceSearchViewModel {
        JellyfinMultiSourceSearchViewModel(dataSource: source) { _ in
            try await Task.sleep(for: .seconds(3600))
        }
    }

    @Test("results from every included server are merged and each hit knows its server")
    func merge() async {
        let one = self.server("Basement")
        let two = self.server("Attic")
        let source = StubBrowseSource()
        source.searchResults[one.id] = JellyfinSearchResult(
            songs: [jfSong("s1")],
            albums: [JellyfinAlbum(id: "a1", title: "A1")],
            artists: [JellyfinArtist(id: "r1", name: "R1")]
        )
        source.searchResults[two.id] = JellyfinSearchResult(songs: [jfSong("s1"), jfSong("s2")])
        let search = self.patientSearch(source)
        search.search(query: "wave", servers: [one, two])
        #expect(await waitUntil { !search.isSearching })
        #expect(search.songs.count == 3)
        #expect(Set(search.songs.map(\.id)).count == 3, "the same item id on two servers must stay two hits")
        #expect(Set(search.songs.map(\.serverName)) == ["Basement", "Attic"])
        #expect(search.albums.map(\.serverName) == ["Basement"])
        #expect(search.artists.count == 1)
        #expect(search.rows.count == 3 && search.rows.map(\.serverName).contains("Attic"))
        #expect(search.failedServerNames.isEmpty)
    }

    @Test("a server that is left out of global search is not asked")
    func excluded() async {
        let included = self.server("In")
        let excluded = self.server("Out", search: false)
        let source = StubBrowseSource()
        source.searchResults[included.id] = JellyfinSearchResult(songs: [jfSong("in")])
        source.searchResults[excluded.id] = JellyfinSearchResult(songs: [jfSong("out")])
        let search = self.patientSearch(source)
        search.search(query: "x", servers: [included, excluded])
        #expect(await waitUntil { !search.isSearching })
        #expect(search.songs.map(\.song.id) == ["in"])
    }

    @Test("a server that fails is named and the others still show")
    func failureIsNamed() async {
        let good = self.server("Good")
        let bad = self.server("Bad")
        let source = StubBrowseSource()
        source.searchResults[good.id] = JellyfinSearchResult(songs: [jfSong("g")])
        source.failSearch = [bad.id]
        let search = self.patientSearch(source)
        search.search(query: "x", servers: [good, bad])
        #expect(await waitUntil { !search.isSearching })
        #expect(search.failedServerNames == ["Bad"])
        #expect(search.songs.map(\.song.id) == ["g"])
    }

    @Test("a slow server is dropped at the soft timeout and named, and does not hold the rest back")
    func slowServer() async {
        let fast = self.server("Fast")
        let slow = self.server("Slow")
        let source = StubBrowseSource()
        source.searchResults[fast.id] = JellyfinSearchResult(songs: [jfSong("f")])
        source.slowSearch = [slow.id]
        // The deadline is held shut until the fast server has answered, so the test
        // decides the order instead of racing the clock.
        let deadline = Guarded(false)
        let search = JellyfinMultiSourceSearchViewModel(dataSource: source) { _ in
            while !deadline.value {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        search.search(query: "x", servers: [fast, slow])
        #expect(await waitUntil { search.songs.count == 1 })
        #expect(search.isSearching, "the slow server is still pending")
        deadline.update { $0 = true }
        #expect(await waitUntil { !search.isSearching })
        #expect(search.songs.map(\.song.id) == ["f"])
        #expect(search.failedServerNames == ["Slow"])
    }

    @Test("an empty query clears every list and a new query replaces the last one")
    func clearAndReplace() async {
        let one = self.server("One")
        let source = StubBrowseSource()
        source.searchResults[one.id] = JellyfinSearchResult(songs: [jfSong("a")])
        let search = self.patientSearch(source)
        search.search(query: "a", servers: [one])
        #expect(await waitUntil { !search.isSearching && search.songs.count == 1 })
        search.search(query: "   ", servers: [one])
        #expect(search.songs.isEmpty && search.query.isEmpty && !search.isSearching)
    }

    @Test("with no server in global search nothing is asked and nothing is left spinning")
    func noServers() {
        let search = JellyfinMultiSourceSearchViewModel(dataSource: StubBrowseSource())
        search.search(query: "x", servers: [self.server("Out", search: false)])
        #expect(!search.isSearching)
        #expect(search.songs.isEmpty)
    }
}

@Suite("Jellyfin song table")
@MainActor
struct JellyfinSongTableTests {
    private let server = UUID()

    private func row(_ song: JellyfinSong, name: String = "Home") -> JellyfinSongTableRow {
        JellyfinSongTableRow(song: song, serverID: self.server, serverName: name)
    }

    @Test("a row shows exactly what the server sent, and a missing field is empty, not invented")
    func rowFields() {
        let song = JellyfinSong(
            id: "i",
            title: "T",
            artistName: "Ar",
            albumTitle: "Al",
            trackNumber: 3,
            discNumber: 2,
            year: 2012,
            genre: "Folk",
            durationSeconds: 240.9,
            bitrateKbps: 960,
            isStarred: true
        )
        let full = self.row(song)
        #expect(full.artist == "Ar" && full.album == "Al" && full.year == 2012 && full.genre == "Folk")
        #expect(full.duration == 240)
        #expect(full.trackNumber == 3 && full.discNumber == 2 && full.bitrate == 960 && full.starred)
        let bare = self.row(JellyfinSong(id: "j", title: "U"))
        #expect(bare.artist.isEmpty && bare.album.isEmpty && bare.year == 0 && bare.duration == 0 && !bare.starred)
    }

    @Test("row ids are scoped by server, so one item id on two servers does not collide")
    func scopedIDs() {
        let other = JellyfinSongTableRow(song: jfSong("same"), serverID: UUID(), serverName: "Other")
        #expect(self.row(jfSong("same")).id != other.id)
        #expect(self.row(jfSong("same")).id == JellyfinSongTableRow.id(serverID: self.server, songID: "same"))
    }

    @Test("only the rows whose displayed values moved are reloaded; a new row is not a content change")
    func changedRows() {
        let before = [self.row(jfSong("a")), self.row(jfSong("b"))]
        var starred = jfSong("b")
        starred.isStarred = true
        let after = [self.row(jfSong("a")), self.row(starred), self.row(jfSong("c"))]
        let changed = JellyfinSongTable.changedRowIDs(
            from: Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) }),
            to: after
        )
        #expect(changed == [after[1].id])
    }

    @Test("a renamed server counts as a content change of every row")
    func renameIsContent() {
        #expect(!self.row(jfSong("a"), name: "Home").hasSameContent(as: self.row(jfSong("a"), name: "Attic")))
        #expect(self.row(jfSong("a")).hasSameContent(as: self.row(jfSong("a"))))
    }

    @Test("a dragged row survives the pasteboard round trip, and garbage on the pasteboard is skipped")
    func dragRoundTrip() throws {
        let payload = JellyfinSongDragPayload(
            serverID: self.server, songID: "i", title: "T", artist: "Ar", album: "Al", genre: "Folk", durationSeconds: 241
        )
        let item = try #require(JellyfinSongDrag.pasteboardItem(for: [payload]))
        #expect(JellyfinSongDrag.payloads(from: [item]) == [payload])
        #expect(JellyfinSongDrag.pasteboardItem(for: []) == nil)
        let bad = NSPasteboardItem()
        bad.setData(Data("nope".utf8), forType: .bocanJellyfinSong)
        #expect(JellyfinSongDrag.payloads(from: [bad]).isEmpty)
        #expect(NSPasteboard.PasteboardType.bocanJellyfinSong != .bocanSubsonicSong)
    }

    @Test("durations format as m:ss and an unknown one is blank")
    func durations() {
        #expect(JellyfinSongTableCoordinator.formatDuration(241) == "4:01")
        #expect(JellyfinSongTableCoordinator.formatDuration(0).isEmpty)
        #expect(JellyfinAlbumDetailView.formatTotalDuration(3725) == "1:02:05")
        #expect(JellyfinAlbumDetailView.formatTotalDuration(125) == "2:05")
    }
}

@Suite("Jellyfin navigation")
struct JellyfinNavigationTests {
    private let server = UUID()

    @Test("Esc from a Jellyfin drill-down goes to that server's list")
    func parents() {
        #expect(LibraryViewModel.parentDestination(of: .jellyfinAlbum(self.server, "x")) == .jellyfinAlbums(self.server))
        #expect(LibraryViewModel.parentDestination(of: .jellyfinArtist(self.server, "x")) == .jellyfinArtists(self.server))
        #expect(LibraryViewModel.parentDestination(of: .jellyfinPlaylist(self.server, "x")) == .jellyfinPlaylists(self.server))
        #expect(LibraryViewModel.parentDestination(of: .jellyfinSongs(self.server)) == nil)
    }

    @Test("an album is opened from the Albums list, an artist or Recently Added of the same server, and no other")
    func albumContainers() {
        let album = SidebarDestination.jellyfinAlbum(self.server, "x")
        #expect(LibraryViewModel.isPlausibleContainer(.jellyfinAlbums(self.server), of: album))
        #expect(LibraryViewModel.isPlausibleContainer(.jellyfinArtist(self.server, "y"), of: album))
        #expect(LibraryViewModel.isPlausibleContainer(.jellyfinRecentlyAdded(self.server), of: album))
        #expect(!LibraryViewModel.isPlausibleContainer(.jellyfinAlbums(UUID()), of: album), "another server is not a container")
        #expect(!LibraryViewModel.isPlausibleContainer(.albums, of: album))
        #expect(!LibraryViewModel.isPlausibleContainer(.subsonicAlbums(self.server), of: album))
    }

    @Test("the drill-downs report their server and survive the saved-state round trip")
    func drillDowns() throws {
        for destination in [
            SidebarDestination.jellyfinAlbum(self.server, "a1"),
            .jellyfinArtist(self.server, "r1"),
            .jellyfinPlaylist(self.server, "p1"),
        ] {
            #expect(destination.jellyfinServerID == self.server)
            let data = try JSONEncoder().encode(destination)
            #expect(try JSONDecoder().decode(SidebarDestination.self, from: data) == destination)
        }
    }
}
