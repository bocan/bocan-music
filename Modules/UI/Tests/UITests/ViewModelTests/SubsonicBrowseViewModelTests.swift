// swiftlint:disable file_length
import Foundation
import Subsonic
import SwiftSonic
import Testing
@testable import UI

// MARK: - Test stub

private actor StubBrowseDataSource: SubsonicBrowseDataSource {
    var randomSongPages: [[Song]] = []
    var albumPages: [[AlbumID3]] = []
    var artistsIndex: [ArtistIndex] = []
    var genresList: [Genre] = []
    var songsByGenre: [String: [[Song]]] = [:]
    var failNextRandom = false
    var randomCallCount = 0
    var albumCallCount = 0
    var lastAlbumOffset: Int?
    var lastGenreOffsets: [Int] = []

    func seedRandomPages(_ pages: [[Song]]) {
        self.randomSongPages = pages
    }

    func seedAlbumPages(_ pages: [[AlbumID3]]) {
        self.albumPages = pages
    }

    func seedArtists(_ index: [ArtistIndex]) {
        self.artistsIndex = index
    }

    func seedGenres(_ genres: [Genre]) {
        self.genresList = genres
    }

    func seedGenrePages(_ pages: [[Song]], for genre: String) {
        self.songsByGenre[genre] = pages
    }

    func setFailNextRandom(_ value: Bool) {
        self.failNextRandom = value
    }

    func getArtists(serverID: UUID) async throws -> [ArtistIndex] {
        self.artistsIndex
    }

    func getGenres(serverID: UUID) async throws -> [Genre] {
        self.genresList
    }

    func getAlbumList2(
        serverID: UUID,
        type: AlbumListType,
        size: Int,
        offset: Int
    ) async throws -> [AlbumID3] {
        self.albumCallCount += 1
        self.lastAlbumOffset = offset
        guard !self.albumPages.isEmpty else { return [] }
        return self.albumPages.removeFirst()
    }

    func getRandomSongs(serverID: UUID, size: Int) async throws -> [Song] {
        self.randomCallCount += 1
        if self.failNextRandom {
            self.failNextRandom = false
            throw TestError.boom
        }
        guard !self.randomSongPages.isEmpty else { return [] }
        return self.randomSongPages.removeFirst()
    }

    func getSongsByGenre(
        serverID: UUID,
        genre: String,
        count: Int,
        offset: Int
    ) async throws -> [Song] {
        self.lastGenreOffsets.append(offset)
        var pages = self.songsByGenre[genre] ?? []
        guard !pages.isEmpty else { return [] }
        let next = pages.removeFirst()
        self.songsByGenre[genre] = pages
        return next
    }

    func getArtist(serverID: UUID, id: String) async throws -> ArtistID3 {
        ArtistID3(id: id, name: "Stub")
    }

    func getAlbum(serverID: UUID, id: String) async throws -> AlbumID3 {
        AlbumID3(id: id, name: "Stub", songCount: 0, duration: 0)
    }

    // MARK: Phase 19 step 11 — optional destinations

    var playlistsList: [Playlist] = []
    var playlistDetailValue: PlaylistWithSongs?
    var starredValue: Starred2 = makeStarred2()
    var podcastsList: [PodcastChannel] = []
    var stationsList: [InternetRadioStation] = []
    var bookmarksList: [Bookmark] = []
    var failNextOptional = false

    func seedPlaylists(_ list: [Playlist]) {
        self.playlistsList = list
    }

    func seedPlaylistDetail(_ pl: PlaylistWithSongs) {
        self.playlistDetailValue = pl
    }

    func seedStarred(_ s: Starred2) {
        self.starredValue = s
    }

    func seedPodcasts(_ list: [PodcastChannel]) {
        self.podcastsList = list
    }

    func seedStations(_ list: [InternetRadioStation]) {
        self.stationsList = list
    }

    func seedBookmarks(_ list: [Bookmark]) {
        self.bookmarksList = list
    }

    func setFailNextOptional(_ value: Bool) {
        self.failNextOptional = value
    }

    private func failIfRequested() throws {
        if self.failNextOptional {
            self.failNextOptional = false
            throw TestError.boom
        }
    }

    func getPlaylists(serverID: UUID) async throws -> [Playlist] {
        try self.failIfRequested()
        return self.playlistsList
    }

    func getPlaylist(serverID: UUID, id: String) async throws -> PlaylistWithSongs {
        try self.failIfRequested()
        guard let pl = self.playlistDetailValue else { throw TestError.boom }
        return pl
    }

    func getStarred2(serverID: UUID) async throws -> Starred2 {
        try self.failIfRequested()
        return self.starredValue
    }

    func getPodcasts(serverID: UUID) async throws -> [PodcastChannel] {
        try self.failIfRequested()
        return self.podcastsList
    }

    func getInternetRadioStations(serverID: UUID) async throws -> [InternetRadioStation] {
        try self.failIfRequested()
        return self.stationsList
    }

    func getBookmarks(serverID: UUID) async throws -> [Bookmark] {
        try self.failIfRequested()
        return self.bookmarksList
    }

    // MARK: Phase 19 step 13 — federated search

    var searchResult: SearchResult3 = makeSearchResult()
    var searchDelay: Duration?
    var failNextSearch = false
    var searchCallCount = 0
    var lastSearchQuery: String?

    func seedSearchResult(_ result: SearchResult3) {
        self.searchResult = result
    }

    func setSearchDelay(_ delay: Duration?) {
        self.searchDelay = delay
    }

    func setFailNextSearch(_ value: Bool) {
        self.failNextSearch = value
    }

    func search3(
        serverID: UUID,
        query: String,
        artistCount _: Int,
        albumCount _: Int,
        songCount _: Int
    ) async throws -> SearchResult3 {
        self.searchCallCount += 1
        self.lastSearchQuery = query
        if let delay = self.searchDelay {
            try await Task.sleep(for: delay)
        }
        if self.failNextSearch {
            self.failNextSearch = false
            throw TestError.boom
        }
        return self.searchResult
    }
}

private enum TestError: Error { case boom }

// MARK: - InMemoryMetadataCache

/// Test stub for `SubsonicMetadataCaching`. Records writes so tests can
/// assert "the view-model saved a fresh snapshot after the network fetch".
private final class InMemoryMetadataCache: SubsonicMetadataCaching, @unchecked Sendable {
    private var store: [String: Data] = [:]
    private(set) var saveCount = 0

    func seed(serverID: UUID, entityKind: String, entityID: String, payload: Data) {
        self.store[Self.key(serverID, entityKind, entityID)] = payload
    }

    func loadCache(serverID: UUID, entityKind: String, entityID: String) async -> Data? {
        self.store[Self.key(serverID, entityKind, entityID)]
    }

    func saveCache(serverID: UUID, entityKind: String, entityID: String, payload: Data) async {
        self.saveCount += 1
        self.store[Self.key(serverID, entityKind, entityID)] = payload
    }

    private static func key(_ id: UUID, _ kind: String, _ entity: String) -> String {
        "\(id.uuidString)|\(kind)|\(entity)"
    }
}

private func song(_ i: Int, genre: String? = nil) -> Song {
    Song(id: "s\(i)", title: "Song \(i)", artist: "Artist", genre: genre, duration: 200)
}

private func album(_ i: Int) -> AlbumID3 {
    AlbumID3(id: "a\(i)", name: "Album \(i)", songCount: 10, duration: 1800, artist: "Artist \(i)")
}

private func makeGenre(value: String, songCount: Int, albumCount: Int) -> Genre {
    let json = """
    {"value":"\(value)","songCount":\(songCount),"albumCount":\(albumCount)}
    """
    return try! JSONDecoder().decode(Genre.self, from: Data(json.utf8)) // swiftlint:disable:this force_try
}

private func makeSearchResult(
    artists: [String] = [],
    albums: [String] = [],
    songs: [String] = []
) -> SearchResult3 {
    let artistJSON = artists.map { #"{"id":"\#($0)","name":"\#($0)"}"# }.joined(separator: ",")
    let albumJSON = albums.map { #"{"id":"\#($0)","name":"\#($0)","songCount":1,"duration":100}"# }.joined(separator: ",")
    let songJSON = songs.map { #"{"id":"\#($0)","title":"\#($0)"}"# }.joined(separator: ",")
    var parts: [String] = []
    if !artists.isEmpty { parts.append(#""artist":[\#(artistJSON)]"#) }
    if !albums.isEmpty { parts.append(#""album":[\#(albumJSON)]"#) }
    if !songs.isEmpty { parts.append(#""song":[\#(songJSON)]"#) }
    let json = "{\(parts.joined(separator: ","))}"
    return try! JSONDecoder().decode(SearchResult3.self, from: Data(json.utf8)) // swiftlint:disable:this force_try
}

private let serverID = UUID()

// MARK: - SubsonicSongsViewModel

@Suite("SubsonicSongsViewModel")
@MainActor
struct SubsonicSongsViewModelTests {
    @Test("load() populates songs and clears errorMessage")
    func loadPopulates() async {
        let stub = StubBrowseDataSource()
        await stub.seedRandomPages([[song(1), song(2), song(3)]])
        let vm = SubsonicSongsViewModel(serverID: serverID, dataSource: stub)

        await vm.load()

        #expect(vm.songs.count == 3)
        #expect(vm.errorMessage == nil)
        #expect(vm.isLoading == false)
    }

    @Test("loadMore() appends and dedupes by id")
    func loadMoreDedupes() async {
        let stub = StubBrowseDataSource()
        // page 1: full page of 100; page 2: overlaps song 100 and adds 50 more
        let page1 = (0 ..< 100).map { song($0) }
        let page2 = (99 ..< 150).map { song($0) }
        await stub.seedRandomPages([page1, page2])
        let vm = SubsonicSongsViewModel(serverID: serverID, dataSource: stub)

        await vm.load()
        #expect(vm.songs.count == 100)
        #expect(vm.hasMorePages == true)

        await vm.loadMore()
        // 100 + (51 new — 1 dedup) = 150
        #expect(vm.songs.count == 150)
        #expect(Set(vm.songs.map(\.id)).count == 150)
    }

    @Test("Short page sets hasMorePages = false")
    func shortPageStopsPaging() async {
        let stub = StubBrowseDataSource()
        await stub.seedRandomPages([[song(1), song(2)]]) // < pageSize
        let vm = SubsonicSongsViewModel(serverID: serverID, dataSource: stub)
        await vm.load()
        #expect(vm.hasMorePages == false)
    }

    @Test("Error path sets errorMessage and clears isLoading")
    func errorPath() async {
        let stub = StubBrowseDataSource()
        await stub.setFailNextRandom(true)
        let vm = SubsonicSongsViewModel(serverID: serverID, dataSource: stub)
        await vm.load()
        #expect(vm.errorMessage != nil)
        #expect(vm.isLoading == false)
    }
}

// MARK: - SubsonicAlbumsViewModel

@Suite("SubsonicAlbumsViewModel")
@MainActor
struct SubsonicAlbumsViewModelTests {
    @Test("load() hydrates from cache before the network fetch replaces it")
    func cacheHydration() async throws {
        let stub = StubBrowseDataSource()
        let cached = [album(900), album(901)]
        let fresh = [album(0), album(1)]
        let cache = InMemoryMetadataCache()
        let payload = try JSONEncoder().encode(cached)
        cache.seed(
            serverID: serverID,
            entityKind: "albums.firstPage",
            entityID: AlbumListType.alphabeticalByName.rawValue,
            payload: payload
        )
        await stub.seedAlbumPages([fresh])
        let vm = SubsonicAlbumsViewModel(serverID: serverID, dataSource: stub, cache: cache)

        await vm.load()

        // The fresh page replaces the cached one and the new sample is persisted.
        #expect(vm.albums.map(\.id) == fresh.map(\.id))
        #expect(cache.saveCount == 1)
    }

    @Test("loadMore() pages with offset == albums.count")
    func loadMoreOffset() async {
        let stub = StubBrowseDataSource()
        await stub.seedAlbumPages([
            (0 ..< 100).map { album($0) },
            (100 ..< 150).map { album($0) },
        ])
        let vm = SubsonicAlbumsViewModel(serverID: serverID, dataSource: stub)

        await vm.load()
        #expect(vm.albums.count == 100)
        let firstOffset = await stub.lastAlbumOffset
        #expect(firstOffset == 0)

        await vm.loadMore()
        #expect(vm.albums.count == 150)
        let secondOffset = await stub.lastAlbumOffset
        #expect(secondOffset == 100)
        #expect(vm.hasMorePages == false)
    }
}

// MARK: - SubsonicArtistsViewModel

@Suite("SubsonicArtistsViewModel")
@MainActor
struct SubsonicArtistsViewModelTests {
    @Test("load() writes the fresh sections to the cache after a successful fetch")
    func cacheWriteOnSuccess() async {
        let stub = StubBrowseDataSource()
        let sections: [ArtistIndex] = [
            ArtistIndex(name: "A", artist: [ArtistID3(id: "1", name: "Alice")]),
        ]
        await stub.seedArtists(sections)
        let cache = InMemoryMetadataCache()
        let vm = SubsonicArtistsViewModel(serverID: serverID, dataSource: stub, cache: cache)

        await vm.load()
        #expect(vm.sections.count == 1)
        #expect(cache.saveCount == 1)

        // On a second load() with no live data and only cache, the cached snapshot
        // is restored before the (empty) network response replaces it.
        await stub.seedArtists([])
        let vm2 = SubsonicArtistsViewModel(serverID: serverID, dataSource: stub, cache: cache)
        await vm2.load()
        #expect(vm2.sections.isEmpty) // empty network result wins after hydration
    }

    @Test("load() populates sections and totalArtistCount sums correctly")
    func loadAndCount() async {
        let stub = StubBrowseDataSource()
        let sections: [ArtistIndex] = [
            ArtistIndex(name: "A", artist: [
                ArtistID3(id: "1", name: "Alice"),
                ArtistID3(id: "2", name: "Anna"),
            ]),
            ArtistIndex(name: "B", artist: [
                ArtistID3(id: "3", name: "Bob"),
            ]),
        ]
        await stub.seedArtists(sections)
        let vm = SubsonicArtistsViewModel(serverID: serverID, dataSource: stub)

        await vm.load()

        #expect(vm.sections.count == 2)
        #expect(vm.totalArtistCount == 3)
        #expect(vm.errorMessage == nil)
    }
}

// MARK: - SubsonicGenresViewModel

@Suite("SubsonicGenresViewModel")
@MainActor
struct SubsonicGenresViewModelTests {
    @Test("selectGenre(...) loads first page; nil clears genreSongs")
    func selectAndClear() async {
        let stub = StubBrowseDataSource()
        await stub.seedGenres([makeGenre(value: "Rock", songCount: 50, albumCount: 5)])
        await stub.seedGenrePages([[song(1, genre: "Rock"), song(2, genre: "Rock")]], for: "Rock")
        let vm = SubsonicGenresViewModel(serverID: serverID, dataSource: stub)

        await vm.load()
        #expect(vm.genres.count == 1)

        await vm.selectGenre("Rock")
        #expect(vm.genreSongs.count == 2)
        #expect(vm.selectedGenre == "Rock")

        await vm.selectGenre(nil)
        #expect(vm.genreSongs.isEmpty)
        #expect(vm.selectedGenre == nil)
    }

    @Test("loadMoreGenreSongs() pages with offset = genreSongs.count")
    func paging() async {
        let stub = StubBrowseDataSource()
        await stub.seedGenres([makeGenre(value: "Jazz", songCount: 250, albumCount: 12)])
        let page1 = (0 ..< 100).map { song($0, genre: "Jazz") }
        let page2 = (100 ..< 150).map { song($0, genre: "Jazz") }
        await stub.seedGenrePages([page1, page2], for: "Jazz")
        let vm = SubsonicGenresViewModel(serverID: serverID, dataSource: stub)

        await vm.load()
        await vm.selectGenre("Jazz")
        #expect(vm.genreSongs.count == 100)
        #expect(vm.hasMoreGenreSongs == true)

        await vm.loadMoreGenreSongs()
        #expect(vm.genreSongs.count == 150)
        #expect(vm.hasMoreGenreSongs == false)

        let offsets = await stub.lastGenreOffsets
        #expect(offsets == [0, 100])
    }
}

// MARK: - Step 11 fixtures

private func makePlaylist(id: String, name: String, songCount: Int = 5) -> Playlist {
    Playlist(id: id, name: name, songCount: songCount, duration: songCount * 200)
}

private func makePlaylistDetail(id: String, name: String, songs: [Song]) -> PlaylistWithSongs {
    PlaylistWithSongs(
        id: id,
        name: name,
        songCount: songs.count,
        duration: songs.reduce(0) { $0 + ($1.duration ?? 0) },
        entry: songs
    )
}

private func makeStation(id: String, name: String) -> InternetRadioStation {
    let json = """
    {"id":"\(id)","name":"\(name)","streamUrl":"https://example.com/\(id).mp3","homePageUrl":"https://example.com/\(id)"}
    """
    return try! JSONDecoder().decode(InternetRadioStation.self, from: Data(json.utf8)) // swiftlint:disable:this force_try
}

private func makeStarred2(songIDs: [String] = [], artistIDs: [String] = [], albumIDs: [String] = []) -> Starred2 {
    let songs = songIDs.map { #"{"id":"\#($0)","title":"S","duration":200}"# }.joined(separator: ",")
    let artists = artistIDs.map { #"{"id":"\#($0)","name":"A"}"# }.joined(separator: ",")
    let albums = albumIDs.map { #"{"id":"\#($0)","name":"Al","songCount":1,"duration":10}"# }.joined(separator: ",")
    let json = "{\"song\":[\(songs)],\"artist\":[\(artists)],\"album\":[\(albums)]}"
    return try! JSONDecoder().decode(Starred2.self, from: Data(json.utf8)) // swiftlint:disable:this force_try
}

private func makeBookmark(songID: String, position: Int) -> Bookmark {
    // position on the wire is milliseconds; pass seconds * 1000 here.
    let json = """
    {
        "position": \(position * 1000),
        "username": "alice",
        "created": "2024-01-01T00:00:00Z",
        "changed": "2024-01-02T00:00:00Z",
        "entry": {"id": "\(songID)", "title": "Bookmarked", "artist": "A", "duration": 300}
    }
    """
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return try! dec.decode(Bookmark.self, from: Data(json.utf8)) // swiftlint:disable:this force_try
}

private func makePodcastChannel(id: String, title: String, episodes: Int = 0) -> PodcastChannel {
    let eps = (0 ..< episodes)
        .map { i in
            """
            {"id":"\(id)-\(i)","channelId":"\(id)","title":"Ep \(i)","status":"completed"}
            """
        }
        .joined(separator: ",")
    let json = """
    {"id":"\(id)","title":"\(title)","status":"completed","episode":[\(eps)]}
    """
    return try! JSONDecoder().decode(PodcastChannel.self, from: Data(json.utf8)) // swiftlint:disable:this force_try
}

// MARK: - SubsonicPlaylistsViewModel

@Suite("SubsonicPlaylistsViewModel")
@MainActor
struct SubsonicPlaylistsViewModelTests {
    @Test("load() populates and sorts playlists by name")
    func loadAndSort() async {
        let stub = StubBrowseDataSource()
        await stub.seedPlaylists([
            makePlaylist(id: "2", name: "Zeppelin"),
            makePlaylist(id: "1", name: "Aretha"),
        ])
        let vm = SubsonicPlaylistsViewModel(serverID: serverID, dataSource: stub)
        await vm.load()
        #expect(vm.playlists.map(\.name) == ["Aretha", "Zeppelin"])
        #expect(vm.errorMessage == nil)
    }

    @Test("Error path sets errorMessage")
    func errorPath() async {
        let stub = StubBrowseDataSource()
        await stub.setFailNextOptional(true)
        let vm = SubsonicPlaylistsViewModel(serverID: serverID, dataSource: stub)
        await vm.load()
        #expect(vm.errorMessage != nil)
    }
}

// MARK: - SubsonicPlaylistDetailViewModel

@Suite("SubsonicPlaylistDetailViewModel")
@MainActor
struct SubsonicPlaylistDetailViewModelTests {
    @Test("load() populates playlist with songs")
    func loadDetail() async {
        let stub = StubBrowseDataSource()
        let detail = makePlaylistDetail(id: "p1", name: "Mix", songs: [song(1), song(2)])
        await stub.seedPlaylistDetail(detail)
        let vm = SubsonicPlaylistDetailViewModel(
            serverID: serverID, playlistID: "p1", dataSource: stub
        )
        await vm.load()
        #expect(vm.playlist?.id == "p1")
        #expect(vm.playlist?.entry?.count == 2)
    }
}

// MARK: - SubsonicStarredViewModel

@Suite("SubsonicStarredViewModel")
@MainActor
struct SubsonicStarredViewModelTests {
    @Test("load() projects starred songs and counts")
    func loadStarred() async {
        let stub = StubBrowseDataSource()
        await stub.seedStarred(makeStarred2(
            songIDs: ["s1", "s2"],
            artistIDs: ["a1"],
            albumIDs: ["al1"]
        ))
        let vm = SubsonicStarredViewModel(serverID: serverID, dataSource: stub)
        await vm.load()
        #expect(vm.songs.count == 2)
        #expect(vm.artistCount == 1)
        #expect(vm.albumCount == 1)
    }

    @Test("Error path sets errorMessage")
    func starredError() async {
        let stub = StubBrowseDataSource()
        await stub.setFailNextOptional(true)
        let vm = SubsonicStarredViewModel(serverID: serverID, dataSource: stub)
        await vm.load()
        #expect(vm.errorMessage != nil)
    }
}

// MARK: - SubsonicPodcastsViewModel

@Suite("SubsonicPodcastsViewModel")
@MainActor
struct SubsonicPodcastsViewModelTests {
    @Test("load() populates channels")
    func loadPodcasts() async {
        let stub = StubBrowseDataSource()
        await stub.seedPodcasts([
            makePodcastChannel(id: "c1", title: "Show", episodes: 2),
        ])
        let vm = SubsonicPodcastsViewModel(serverID: serverID, dataSource: stub)
        await vm.load()
        #expect(vm.channels.count == 1)
        #expect(vm.channels.first?.episode.count == 2)
    }
}

// MARK: - SubsonicInternetRadioViewModel

@Suite("SubsonicInternetRadioViewModel")
@MainActor
struct SubsonicInternetRadioViewModelTests {
    @Test("load() sorts stations by name")
    func loadStations() async {
        let stub = StubBrowseDataSource()
        await stub.seedStations([
            makeStation(id: "2", name: "Zen FM"),
            makeStation(id: "1", name: "Alpha"),
        ])
        let vm = SubsonicInternetRadioViewModel(serverID: serverID, dataSource: stub)
        await vm.load()
        #expect(vm.stations.map(\.name) == ["Alpha", "Zen FM"])
    }
}

// MARK: - SubsonicBookmarksViewModel

@Suite("SubsonicBookmarksViewModel")
@MainActor
struct SubsonicBookmarksViewModelTests {
    @Test("load() populates bookmarks and exposes songs")
    func loadBookmarks() async {
        let stub = StubBrowseDataSource()
        await stub.seedBookmarks([
            makeBookmark(songID: "s1", position: 60),
            makeBookmark(songID: "s2", position: 120),
        ])
        let vm = SubsonicBookmarksViewModel(serverID: serverID, dataSource: stub)
        await vm.load()
        #expect(vm.bookmarks.count == 2)
        #expect(vm.songs.map(\.id) == ["s1", "s2"])
    }
}

// MARK: - FederatedSearchViewModel (Phase 19 step 13)

private func sidebarServer(_ name: String, include: Bool = true) -> SubsonicSidebarServer {
    SubsonicSidebarServer(
        id: UUID(),
        name: name,
        sortIndex: 0,
        includeInGlobalSearch: include
    )
}

@Suite("FederatedSearchViewModel")
@MainActor
struct FederatedSearchViewModelTests {
    @Test("empty query clears sections")
    func emptyClears() {
        let stub = StubBrowseDataSource()
        let vm = FederatedSearchViewModel(dataSource: stub)
        vm.search(query: "", servers: [sidebarServer("A")])
        #expect(vm.sections.isEmpty)
        #expect(vm.query.isEmpty)
    }

    @Test("fan-out populates one section per included server")
    func fanOut() async {
        let stub = StubBrowseDataSource()
        await stub.seedSearchResult(makeSearchResult(songs: ["s1", "s2"]))
        let vm = FederatedSearchViewModel(dataSource: stub)
        let servers = [sidebarServer("A"), sidebarServer("B")]
        vm.search(query: "hello", servers: servers)
        #expect(vm.sections.count == 2)
        #expect(vm.query == "hello")
        // Wait for the fan-out to complete.
        for _ in 0 ..< 50 {
            try? await Task.sleep(for: .milliseconds(20))
            if vm.sections.allSatisfy({ if case .loading = $0.state { false } else { true } }) {
                break
            }
        }
        for section in vm.sections {
            guard case let .success(result) = section.state else {
                Issue.record("Section \(section.serverName) didn't succeed")
                continue
            }
            #expect(result.song?.count == 2)
        }
    }

    @Test("excluded servers are filtered out before search")
    func excludesDisabled() async {
        let stub = StubBrowseDataSource()
        await stub.seedSearchResult(makeSearchResult(songs: ["s1"]))
        let vm = FederatedSearchViewModel(dataSource: stub)
        let servers = [
            sidebarServer("A", include: true),
            sidebarServer("B", include: false),
        ]
        vm.search(query: "hi", servers: servers)
        #expect(vm.sections.count == 1)
        #expect(vm.sections.first?.serverName == "A")
    }

    @Test("per-server failure surfaces as .failure state")
    func failureSurfaces() async {
        let stub = StubBrowseDataSource()
        await stub.setFailNextSearch(true)
        let vm = FederatedSearchViewModel(dataSource: stub)
        vm.search(query: "hi", servers: [sidebarServer("A")])
        for _ in 0 ..< 50 {
            try? await Task.sleep(for: .milliseconds(20))
            if case .failure = vm.sections.first?.state { break }
        }
        guard case .failure = vm.sections.first?.state else {
            Issue.record("Expected .failure state")
            return
        }
    }

    @Test("slow server exceeds timeout and surfaces as .timedOut")
    func timeoutSurfaces() async {
        let stub = StubBrowseDataSource()
        await stub.setSearchDelay(.milliseconds(500))
        let vm = FederatedSearchViewModel(dataSource: stub, timeout: .milliseconds(50))
        vm.search(query: "hi", servers: [sidebarServer("A")])
        for _ in 0 ..< 50 {
            try? await Task.sleep(for: .milliseconds(30))
            if case .timedOut = vm.sections.first?.state { break }
        }
        guard case .timedOut = vm.sections.first?.state else {
            Issue.record("Expected .timedOut state")
            return
        }
    }

    @Test("clear() cancels in-flight and empties sections")
    func clearCancels() {
        let stub = StubBrowseDataSource()
        let vm = FederatedSearchViewModel(dataSource: stub)
        vm.search(query: "hi", servers: [sidebarServer("A")])
        vm.clear()
        #expect(vm.sections.isEmpty)
        #expect(vm.query.isEmpty)
    }
}
