import Foundation
import Persistence
import Testing
@testable import Jellyfin

@Suite("JellyfinService", .serialized)
struct JellyfinServiceTests {
    private struct Harness {
        let service: JellyfinService
        let repository: JellyfinServerRepository
        let stub: StubJellyfinClient
        let serverID: UUID
    }

    /// A service with one server row (no Keychain item) and a stub client registered for it.
    private func makeHarness(syncStars: Bool = true, scrobble: Bool = true) async throws -> Harness {
        let database = try await Persistence.Database(location: .inMemory)
        let repository = JellyfinServerRepository(database: database)
        let store = JellyfinServerStore(
            repository: repository,
            keychainService: "io.cloudcauldron.bocan.jellyfin.test.\(UUID().uuidString)"
        )
        let id = UUID()
        try await repository.insert(JellyfinServerDTO(
            id: id,
            name: "Home-\(id.uuidString.prefix(6))",
            serverURL: URL(string: "https://jf.example.test") ?? URL(filePath: "/"),
            userID: "user-1",
            deviceID: "DEVICE-1",
            scrobble: scrobble,
            syncStars: syncStars
        ))
        let stub = StubJellyfinClient()
        let service = JellyfinService(
            store: store,
            identity: JellyfinClientIdentity(client: "Bocan", deviceName: "Test", version: "1")
        ) { _ in stub }
        await service.registerClientForTesting(stub, serverID: id)
        return Harness(service: service, repository: repository, stub: stub, serverID: id)
    }

    @Test("an unknown server throws unknownServer from every kind of call")
    func unknownServer() async throws {
        let harness = try await self.makeHarness()
        let other = UUID()
        let expected = JellyfinError.unknownServer(other)
        let service = harness.service
        await #expect(throws: expected) {
            try await service.ping(serverID: other)
        }
        await #expect(throws: expected) {
            _ = try await service.songs(serverID: other)
        }
        await #expect(throws: expected) {
            _ = try await service.starred(serverID: other)
        }
        await #expect(throws: expected) {
            _ = try await service.streamURL(serverID: other, itemID: "x")
        }
        await #expect(throws: expected) {
            try await service.setFavorite(serverID: other, itemID: "x", isFavorite: true)
        }
    }

    @Test("removeClient forgets the server")
    func removeClient() async throws {
        let harness = try await self.makeHarness()
        try await harness.service.ping(serverID: harness.serverID)
        await harness.service.removeClient(for: harness.serverID)
        await #expect(throws: JellyfinError.unknownServer(harness.serverID)) {
            try await harness.service.ping(serverID: harness.serverID)
        }
    }

    @Test("ping and serverInfo go to the client")
    func pingAndInfo() async throws {
        let harness = try await self.makeHarness()
        try await harness.service.ping(serverID: harness.serverID)
        let info = try await harness.service.serverInfo(serverID: harness.serverID)
        #expect(info.version == "10.10.7")
        #expect(harness.stub.calls.value == ["ping", "serverInfo"])
    }

    @Test("a client error passes through unchanged")
    func errorPassesThrough() async throws {
        let harness = try await self.makeHarness()
        harness.stub.onPing = { throw JellyfinError.unauthorized }
        await #expect(throws: JellyfinError.unauthorized) {
            try await harness.service.ping(serverID: harness.serverID)
        }
    }

    // MARK: Query shapes

    @Test("songs are sorted by artist, album, disc and track, and paged")
    func songsQuery() async throws {
        let harness = try await self.makeHarness()
        _ = try await harness.service.songs(serverID: harness.serverID, startIndex: 200, limit: 100)
        let query = try #require(harness.stub.songQueries.value.first)
        #expect(query.kind == .song)
        #expect(query.sort == [.albumArtist, .album, .discNumber, .trackNumber])
        #expect(query.startIndex == 200)
        #expect(query.limit == 100)
    }

    @Test("albums: alphabetical by name, recently added newest first")
    func albumQueries() async throws {
        let harness = try await self.makeHarness()
        _ = try await harness.service.albums(serverID: harness.serverID, list: .alphabetical)
        _ = try await harness.service.albums(serverID: harness.serverID, list: .recentlyAdded, limit: 20)
        let queries = harness.stub.albumQueries.value
        #expect(queries[0].sort == [.sortName])
        #expect(queries[0].descending == false)
        #expect(queries[1].sort == [.dateCreated])
        #expect(queries[1].descending)
        #expect(queries[1].limit == 20)
    }

    @Test("random and most played are the two songs queries they say")
    func randomAndMostPlayed() async throws {
        let harness = try await self.makeHarness()
        _ = try await harness.service.randomSongs(serverID: harness.serverID, limit: 30)
        _ = try await harness.service.mostPlayedSongs(serverID: harness.serverID, limit: 40)
        let queries = harness.stub.songQueries.value
        #expect(queries[0].sort == [.random])
        #expect(queries[0].limit == 30)
        #expect(queries[1].sort == [.playCount])
        #expect(queries[1].descending)
        #expect(queries[1].limit == 40)
    }

    @Test("songs by genre and album songs carry the right filter")
    func genreAndAlbumSongs() async throws {
        let harness = try await self.makeHarness()
        _ = try await harness.service.songsByGenre(serverID: harness.serverID, genreID: "g1")
        _ = try await harness.service.albumSongs(serverID: harness.serverID, albumID: "al1")
        let queries = harness.stub.songQueries.value
        #expect(queries[0].genreID == "g1")
        #expect(queries[1].parentID == "al1")
        #expect(queries[1].sort == [.discNumber, .trackNumber])
    }

    @Test("album and artist by id ask for exactly that id")
    func byID() async throws {
        let harness = try await self.makeHarness()
        harness.stub.onAlbums = { _ in JellyfinPage(items: [JellyfinAlbum(id: "al1", title: "T")]) }
        let album = try await harness.service.album(serverID: harness.serverID, id: "al1")
        let missing = try await harness.service.artist(serverID: harness.serverID, id: "none")
        #expect(album?.title == "T")
        #expect(missing == nil)
        #expect(harness.stub.albumQueries.value.first?.ids == ["al1"])
        #expect(harness.stub.artistQueries.value.first?.ids == ["none"])
    }

    @Test("an artist's albums are filtered by album artist, newest first")
    func artistAlbums() async throws {
        let harness = try await self.makeHarness()
        _ = try await harness.service.artistAlbums(serverID: harness.serverID, artistID: "ar1")
        let query = try #require(harness.stub.albumQueries.value.first)
        #expect(query.albumArtistID == "ar1")
        #expect(query.descending)
    }

    @Test("starred runs three favourite-only queries and joins them")
    func starred() async throws {
        let harness = try await self.makeHarness()
        harness.stub.onSongs = { _ in JellyfinPage(items: [JellyfinSong(id: "s1", title: "S", isStarred: true)]) }
        harness.stub.onAlbums = { _ in JellyfinPage(items: [JellyfinAlbum(id: "a1", title: "A", isStarred: true)]) }
        harness.stub.onArtists = { _ in JellyfinPage(items: [JellyfinArtist(id: "r1", name: "R", isStarred: true)]) }
        let result = try await harness.service.starred(serverID: harness.serverID)
        #expect(result.songs.map(\.id) == ["s1"])
        #expect(result.albums.map(\.id) == ["a1"])
        #expect(result.artists.map(\.id) == ["r1"])
        #expect(harness.stub.songQueries.value.first?.favoritesOnly == true)
        #expect(harness.stub.albumQueries.value.first?.favoritesOnly == true)
        #expect(harness.stub.artistQueries.value.first?.favoritesOnly == true)
    }

    @Test("search runs three parallel queries with the term and the caps")
    func search() async throws {
        let harness = try await self.makeHarness()
        let result = try await harness.service.search(
            serverID: harness.serverID,
            query: "wood",
            artistCount: 3,
            albumCount: 4,
            songCount: 5
        )
        #expect(result.isEmpty)
        #expect(harness.stub.songQueries.value.first?.searchTerm == "wood")
        #expect(harness.stub.songQueries.value.first?.limit == 5)
        #expect(harness.stub.albumQueries.value.first?.limit == 4)
        #expect(harness.stub.artistQueries.value.first?.limit == 3)
    }

    @Test("if one of the three search queries fails the search fails")
    func searchFailure() async throws {
        let harness = try await self.makeHarness()
        harness.stub.onAlbums = { _ in throw JellyfinError.http(status: 500) }
        await #expect(throws: JellyfinError.http(status: 500)) {
            _ = try await harness.service.search(serverID: harness.serverID, query: "x")
        }
    }

    // MARK: Writes and reports

    @Test("setFavorite reaches the client with the item and the state")
    func favorite() async throws {
        let harness = try await self.makeHarness()
        try await harness.service.setFavorite(serverID: harness.serverID, itemID: "i1", isFavorite: true)
        #expect(harness.stub.favorites.value.map(\.itemID) == ["i1"])
        #expect(harness.stub.favorites.value.map(\.isFavorite) == [true])
    }

    @Test("play reports reach the client; a stop carries the tick count as given")
    func reports() async throws {
        let harness = try await self.makeHarness()
        try await harness.service.reportPlaybackStarted(serverID: harness.serverID, itemID: "i1")
        try await harness.service.reportPlaybackStopped(serverID: harness.serverID, itemID: "i1", positionTicks: 2_405_000_000)
        #expect(harness.stub.calls.value == ["started:i1", "stopped:i1"])
        #expect(harness.stub.stops.value.first?.ticks == 2_405_000_000)
    }

    @Test("endSession never throws, even when the server refuses")
    func endSessionIsBestEffort() async throws {
        let harness = try await self.makeHarness()
        harness.stub.onSignOut = { throw JellyfinError.http(status: 500) }
        await harness.service.endSession(serverID: harness.serverID)
        await harness.service.endSession(serverID: UUID())
        #expect(harness.stub.calls.value == ["signOut"])
    }

    @Test("removing a server ends its token, deletes the row and drops the client")
    func removeServerEndsTheSession() async throws {
        let harness = try await self.makeHarness()
        try await harness.service.removeServer(id: harness.serverID)
        #expect(harness.stub.calls.value == ["signOut"])
        #expect(try await harness.repository.fetch(id: harness.serverID) == nil)
        await #expect(throws: JellyfinError.unknownServer(harness.serverID)) {
            try await harness.service.ping(serverID: harness.serverID)
        }
    }

    @Test("a server that refuses the sign-out is still removed")
    func removeServerSurvivesARefusedSignOut() async throws {
        let harness = try await self.makeHarness()
        harness.stub.onSignOut = { throw JellyfinError.http(status: 500) }
        try await harness.service.removeServer(id: harness.serverID)
        #expect(try await harness.repository.fetch(id: harness.serverID) == nil)
    }

    @Test("removing a server runs the removal handler once, with that server's id")
    func removeServerRunsTheHandler() async throws {
        let harness = try await self.makeHarness()
        let removed = Locked<[UUID]>([])
        await harness.service.setServerRemovedHandler { id in removed.update { $0.append(id) } }
        try await harness.service.removeServer(id: harness.serverID)
        #expect(removed.value == [harness.serverID])
    }

    // MARK: Flags

    @Test("the syncStars and scrobble flags are read from the row")
    func flags() async throws {
        let on = try await self.makeHarness(syncStars: true, scrobble: true)
        let off = try await self.makeHarness(syncStars: false, scrobble: false)
        #expect(await on.service.syncsStars(serverID: on.serverID))
        #expect(await on.service.reportsPlays(serverID: on.serverID))
        #expect(await !off.service.syncsStars(serverID: off.serverID))
        #expect(await !off.service.reportsPlays(serverID: off.serverID))
    }

    @Test("a flag for an unknown server reads false")
    func flagUnknownServer() async throws {
        let harness = try await self.makeHarness()
        #expect(await !harness.service.syncsStars(serverID: UUID()))
        #expect(await !harness.service.reportsPlays(serverID: UUID()))
    }

    // MARK: Media URLs

    @Test("media URLs come from the client, and the cover provider skips an item with no image")
    func mediaURLs() async throws {
        let harness = try await self.makeHarness()
        let stream = try await harness.service.streamURL(serverID: harness.serverID, itemID: "i1", format: .mp3, bitrate: .kbps(192))
        #expect(stream.path == "/stream/i1/mp3/192")
        let cover = JellyfinCoverArtProvider(service: harness.service)
        let url = try await cover.coverArtURL(serverID: harness.serverID, itemID: "al1", tag: "t1", size: 300)
        #expect(url?.path == "/image/al1/t1/300")
        let none = try await cover.coverArtURL(serverID: harness.serverID, itemID: nil, tag: nil)
        #expect(none == nil)
    }

    @Test("the cover provider rethrows a service error")
    func coverProviderError() async throws {
        let harness = try await self.makeHarness()
        let cover = JellyfinCoverArtProvider(service: harness.service)
        await #expect(throws: JellyfinError.unknownServer(UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID())) {
            _ = try await cover.coverArtURL(
                serverID: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
                itemID: "x",
                tag: nil
            )
        }
    }

    // MARK: Pool

    @Test(
        "reloadClients builds a client per server from the token in the Keychain, and survives one failure",
        .enabled(if: jellyfinKeychainAvailable())
    )
    func reload() async throws {
        let database = try await Persistence.Database(location: .inMemory)
        let repository = JellyfinServerRepository(database: database)
        let keychainService = "io.cloudcauldron.bocan.jellyfin.test.\(UUID().uuidString)"
        let store = JellyfinServerStore(repository: repository, keychainService: keychainService)
        let built = Locked<[JellyfinClientConfiguration]>([])
        let service = JellyfinService(
            store: store,
            identity: JellyfinClientIdentity(client: "Bocan", deviceName: "Test", version: "1")
        ) { configuration in
            built.update { $0.append(configuration) }
            return StubJellyfinClient()
        }
        let good = JellyfinServer(
            name: "Good-\(UUID().uuidString.prefix(6))",
            serverURL: URL(string: "https://good.example.test") ?? URL(filePath: "/"),
            userID: "u-good"
        )
        // A row with no Keychain item: its client cannot be built.
        try await repository.insert(JellyfinServerDTO(
            name: "Broken-\(UUID().uuidString.prefix(6))",
            serverURL: URL(string: "https://broken.example.test") ?? URL(filePath: "/"),
            userID: "u-broken",
            deviceID: "D2"
        ))
        let session = JellyfinSession(userID: "u-good", username: "n", accessToken: "GOOD-TOKEN")
        try await store.add(good, session: session)
        try await service.reloadClients()
        #expect(built.value.count == 1)
        let configuration = try #require(built.value.first)
        #expect(configuration.accessToken == "GOOD-TOKEN")
        #expect(configuration.userID == "u-good")
        #expect(configuration.deviceID == good.deviceID)
        #expect(configuration.identity.client == "Bocan")
        try await service.ping(serverID: good.id)
        try await store.remove(id: good.id)
    }
}
