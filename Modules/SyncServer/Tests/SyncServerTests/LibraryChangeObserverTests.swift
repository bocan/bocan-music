import Foundation
import Persistence
import Testing
@testable import SyncServer

@Suite("LibraryChangeObserver")
struct LibraryChangeObserverTests {
    private func pollGeneration(_ syncMeta: SyncMetaRepository, atLeast target: Int, timeout: Duration = .seconds(3)) async throws -> Int {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let value = try await syncMeta.generation()
            if value >= target { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try await syncMeta.generation()
    }

    @Test("a library change bumps the generation after the debounce")
    func libraryChangeBumps() async throws {
        let database = try await Database(location: .inMemory)
        let syncMeta = SyncMetaRepository(database: database)
        let observer = LibraryChangeObserver(syncMeta: syncMeta, debounce: .milliseconds(50))
        await observer.start()
        defer { Task { await observer.stop() } }

        // Let the observation subscribe and deliver its initial (ignored) value.
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await syncMeta.generation() == 0)

        let tracks = TrackRepository(database: database)
        _ = try await tracks.insert(Track(fileURL: "file:///x.flac", addedAt: 0, updatedAt: 0))

        #expect(try await self.pollGeneration(syncMeta, atLeast: 1) >= 1)
    }

    @Test("a podcast artwork-hash change bumps the generation (22-10)")
    func artworkHashChangeBumps() async throws {
        let database = try await Database(location: .inMemory)
        let syncMeta = SyncMetaRepository(database: database)
        let podcasts = PodcastRepository(database: database)

        // Seed the show before the observer starts; the initial emission is ignored.
        let id = try await podcasts.insert(Podcast(feedURL: "https://a.test/f", title: "A", addedAt: 0))

        let observer = LibraryChangeObserver(syncMeta: syncMeta, debounce: .milliseconds(50))
        await observer.start()
        defer { Task { await observer.stop() } }

        try await Task.sleep(for: .milliseconds(200))
        #expect(try await syncMeta.generation() == 0)

        try await podcasts.setArtwork(id: id, path: "/tmp/a.jpg", hash: "cafe")

        #expect(try await self.pollGeneration(syncMeta, atLeast: 1) >= 1)
    }

    @Test("a profile change also bumps the generation")
    func profileChangeBumps() async throws {
        let database = try await Database(location: .inMemory)
        let syncMeta = SyncMetaRepository(database: database)
        let profiles = SyncProfileRepository(database: database)
        let observer = LibraryChangeObserver(syncMeta: syncMeta, debounce: .milliseconds(50))
        await observer.start()
        defer { Task { await observer.stop() } }

        try await Task.sleep(for: .milliseconds(200))
        try await profiles.setProfileJSON(Data("{\"kind\":\"everything\"}".utf8))

        #expect(try await self.pollGeneration(syncMeta, atLeast: 1) >= 1)
    }
}
