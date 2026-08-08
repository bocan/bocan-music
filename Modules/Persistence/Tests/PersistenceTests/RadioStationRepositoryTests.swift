import Foundation
import Testing
@testable import Persistence

@Suite("RadioStationRepository")
struct RadioStationRepositoryTests {
    private static func sample(
        name: String = "Deep Space One",
        streamURL: String = "https://ice2.somafm.com/deepspaceone-128-mp3",
        homePageURL: String? = nil,
        addedAt: Int64 = 1000
    ) -> RadioStation {
        RadioStation(name: name, streamURL: streamURL, addedAt: addedAt, homePageURL: homePageURL)
    }

    @Test("insert then fetchAll round-trips the station and captures the row id")
    func insertRoundTrips() async throws {
        let db = try await Database(location: .inMemory)
        let repo = RadioStationRepository(database: db)

        let saved = try await repo.insert(Self.sample())
        #expect(saved.id != nil)

        let all = try await repo.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.name == "Deep Space One")
        #expect(all.first?.streamURL == "https://ice2.somafm.com/deepspaceone-128-mp3")
        #expect(all.first?.addedAt == 1000)
    }

    @Test("insert throws on a duplicate stream URL")
    func insertRejectsDuplicates() async throws {
        let db = try await Database(location: .inMemory)
        let repo = RadioStationRepository(database: db)

        try await repo.insert(Self.sample())
        await #expect(throws: (any Error).self) {
            try await repo.insert(Self.sample(name: "Same URL, other name"))
        }
    }

    @Test("fetchAll orders by name, case-insensitively")
    func fetchAllOrdersByName() async throws {
        let db = try await Database(location: .inMemory)
        let repo = RadioStationRepository(database: db)

        try await repo.insert(Self.sample(name: "positively meditation", streamURL: "https://a.example/1"))
        try await repo.insert(Self.sample(name: "Deep Space One", streamURL: "https://a.example/2"))
        try await repo.insert(Self.sample(name: "Ancient FM", streamURL: "https://a.example/3"))

        let all = try await repo.fetchAll()
        #expect(all.map(\.name) == ["Ancient FM", "Deep Space One", "positively meditation"])
    }

    @Test("fetchOne finds by stream URL")
    func fetchOneByStreamURL() async throws {
        let db = try await Database(location: .inMemory)
        let repo = RadioStationRepository(database: db)

        #expect(try await repo.fetchOne(streamURL: "https://a.example/1") == nil)
        try await repo.insert(Self.sample(streamURL: "https://a.example/1"))
        #expect(try await repo.fetchOne(streamURL: "https://a.example/1")?.name == "Deep Space One")
    }

    @Test("update edits the row in place")
    func updateEdits() async throws {
        let db = try await Database(location: .inMemory)
        let repo = RadioStationRepository(database: db)

        var saved = try await repo.insert(Self.sample())
        saved.name = "Renamed"
        saved.homePageURL = "https://somafm.com"
        try await repo.update(saved)

        let fetched = try await repo.fetchOne(streamURL: saved.streamURL)
        #expect(fetched?.name == "Renamed")
        #expect(fetched?.homePageURL == "https://somafm.com")
        #expect(try await repo.fetchAll().count == 1)
    }

    @Test("delete removes the station")
    func deleteRemoves() async throws {
        let db = try await Database(location: .inMemory)
        let repo = RadioStationRepository(database: db)

        let saved = try await repo.insert(Self.sample())
        let id = try #require(saved.id)
        try await repo.delete(id: id)

        #expect(try await repo.fetchAll().isEmpty)
    }

    @Test("upsert inserts a new station and reports the insert")
    func upsertInsertsNew() async throws {
        let db = try await Database(location: .inMemory)
        let repo = RadioStationRepository(database: db)

        let inserted = try await repo.upsert(Self.sample())
        #expect(inserted == true)
        #expect(try await repo.fetchAll().count == 1)
    }

    @Test("upsert on an existing stream URL keeps user edits and reports no insert")
    func upsertKeepsExisting() async throws {
        let db = try await Database(location: .inMemory)
        let repo = RadioStationRepository(database: db)

        try await repo.insert(Self.sample(name: "My Edited Name"))
        let inserted = try await repo.upsert(Self.sample(name: "Imported Name"))

        #expect(inserted == false)
        let all = try await repo.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.name == "My Edited Name")
    }

    @Test("recordConnection stamps the profile and last_connected_at")
    func recordConnectionFillsProfile() async throws {
        let db = try await Database(location: .inMemory)
        let repo = RadioStationRepository(database: db)
        let url = Self.sample().streamURL

        try await repo.insert(Self.sample())
        try await repo.recordConnection(
            streamURL: url,
            at: 2000,
            genre: "Ambient",
            stationDescription: "Space music for space travel",
            homePageURL: "https://somafm.com",
            lastCodec: "mp3",
            lastBitrateKbps: 128,
            lastContainer: "mp3",
            lastSampleRateHz: 44100,
            lastChannels: 2
        )

        let fetched = try #require(try await repo.fetchOne(streamURL: url))
        #expect(fetched.genre == "Ambient")
        #expect(fetched.stationDescription == "Space music for space travel")
        #expect(fetched.homePageURL == "https://somafm.com")
        #expect(fetched.lastCodec == "mp3")
        #expect(fetched.lastBitrateKbps == 128)
        #expect(fetched.lastContainer == "mp3")
        #expect(fetched.lastSampleRateHz == 44100)
        #expect(fetched.lastChannels == 2)
        #expect(fetched.lastConnectedAt == 2000)
    }

    @Test("recordConnection keeps stored profile values when headers are absent")
    func recordConnectionKeepsValues() async throws {
        let db = try await Database(location: .inMemory)
        let repo = RadioStationRepository(database: db)
        let url = Self.sample().streamURL

        try await repo.insert(Self.sample())
        try await repo.recordConnection(streamURL: url, at: 2000, genre: "Ambient", lastCodec: "mp3")
        try await repo.recordConnection(streamURL: url, at: 3000)

        let fetched = try #require(try await repo.fetchOne(streamURL: url))
        #expect(fetched.genre == "Ambient")
        #expect(fetched.lastCodec == "mp3")
        #expect(fetched.lastConnectedAt == 3000)
    }

    @Test("recordConnection only fills a NULL home page, never overwrites the user's")
    func recordConnectionHomePage() async throws {
        let db = try await Database(location: .inMemory)
        let repo = RadioStationRepository(database: db)

        try await repo.insert(Self.sample(
            streamURL: "https://a.example/1",
            homePageURL: "https://my.example"
        ))
        try await repo.insert(Self.sample(streamURL: "https://a.example/2"))

        try await repo.recordConnection(
            streamURL: "https://a.example/1",
            at: 2000,
            homePageURL: "https://icy.example"
        )
        try await repo.recordConnection(
            streamURL: "https://a.example/2",
            at: 2000,
            homePageURL: "https://icy.example"
        )

        #expect(try await repo.fetchOne(streamURL: "https://a.example/1")?.homePageURL == "https://my.example")
        #expect(try await repo.fetchOne(streamURL: "https://a.example/2")?.homePageURL == "https://icy.example")
    }

    @Test("observeAll emits on insert and delete")
    func observeAllEmits() async throws {
        let db = try await Database(location: .inMemory)
        let repo = RadioStationRepository(database: db)
        var iterator = await repo.observeAll().makeAsyncIterator()

        let initial = try await iterator.next()
        #expect(initial?.isEmpty == true)

        let saved = try await repo.insert(Self.sample())
        let afterInsert = try await iterator.next()
        #expect(afterInsert?.count == 1)

        try await repo.delete(id: #require(saved.id))
        let afterDelete = try await iterator.next()
        #expect(afterDelete?.isEmpty == true)
    }
}
