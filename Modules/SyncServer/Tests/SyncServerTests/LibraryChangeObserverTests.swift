import Foundation
import Persistence
import Testing
@testable import SyncServer

@Suite("LibraryChangeObserver")
struct LibraryChangeObserverTests {
    /// Lets a test change what the injected profile closure reports.
    private final class SendableBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T

        init(_ value: T) {
            self.stored = value
        }

        var value: T {
            get { self.lock.withLock { self.stored } }
            set { self.lock.withLock { self.stored = newValue } }
        }
    }

    private func pollGeneration(_ syncMeta: SyncMetaRepository, atLeast target: Int, timeout: Duration = .seconds(3)) async throws -> Int {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let value = try await syncMeta.generation()
            if value >= target {
                return value
            }
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

    /// The end-of-play write, exactly as `PlayHistoryRecorder` issues it.
    private func recordPlay(_ database: Database, trackID: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                UPDATE tracks
                SET play_count = play_count + 1,
                    last_played_at = 1,
                    play_duration_total = play_duration_total + 90
                WHERE id = ?
                """,
                arguments: [trackID]
            )
        }
    }

    @Test("with an everything profile, finishing a track does not bump the generation (#550)")
    func playDoesNotBumpUnderEverything() async throws {
        let database = try await Database(location: .inMemory)
        let syncMeta = SyncMetaRepository(database: database)
        let tracks = TrackRepository(database: database)
        let trackID = try await tracks.insert(Track(fileURL: "file:///p.flac", addedAt: 0, updatedAt: 0))

        let observer = LibraryChangeObserver(
            syncMeta: syncMeta,
            debounce: .milliseconds(50),
            profile: { .everything(includePodcasts: true) }
        )
        await observer.start()
        defer { Task { await observer.stop() } }
        try await Task.sleep(for: .milliseconds(200))

        // The manifest carries no play count, so the phone has nothing to fetch.
        try await self.recordPlay(database, trackID: trackID)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await syncMeta.generation() == 0, "a play must not make the phone re-poll")

        // Positive control: a manifest column must still bump.
        try await database.write { db in
            try db.execute(sql: "UPDATE tracks SET rating = 5 WHERE id = ?", arguments: [trackID])
        }
        #expect(try await self.pollGeneration(syncMeta, atLeast: 1) >= 1)
    }

    @Test("with a selected-playlists profile, finishing a track still bumps (a smart playlist can key on it)")
    func playBumpsUnderSelectedProfile() async throws {
        let database = try await Database(location: .inMemory)
        let syncMeta = SyncMetaRepository(database: database)
        let tracks = TrackRepository(database: database)
        let trackID = try await tracks.insert(Track(fileURL: "file:///q.flac", addedAt: 0, updatedAt: 0))

        let observer = LibraryChangeObserver(
            syncMeta: syncMeta,
            debounce: .milliseconds(50),
            profile: { .selected(playlistIds: [1], includePodcasts: false) }
        )
        await observer.start()
        defer { Task { await observer.stop() } }
        try await Task.sleep(for: .milliseconds(200))

        try await self.recordPlay(database, trackID: trackID)
        #expect(try await self.pollGeneration(syncMeta, atLeast: 1) >= 1)
    }

    @Test("switching the profile to selected widens the region, so a later play bumps")
    func profileFlipWidensTheRegion() async throws {
        let database = try await Database(location: .inMemory)
        let syncMeta = SyncMetaRepository(database: database)
        let tracks = TrackRepository(database: database)
        let trackID = try await tracks.insert(Track(fileURL: "file:///r.flac", addedAt: 0, updatedAt: 0))
        let profiles = SyncProfileRepository(database: database)

        // The stored profile is what the observer reads back each time.
        let selected = SendableBox(false)
        let observer = LibraryChangeObserver(
            syncMeta: syncMeta,
            debounce: .milliseconds(50),
            profile: { selected.value ? .selected(playlistIds: [1], includePodcasts: false) : .everything(includePodcasts: true) }
        )
        await observer.start()
        defer { Task { await observer.stop() } }
        try await Task.sleep(for: .milliseconds(200))

        // A profile write is itself a change, which is where the observer
        // re-evaluates which region it needs.
        selected.value = true
        try await profiles.setProfileJSON(Data("{\"kind\":\"selected\",\"playlistIds\":[1]}".utf8))
        let afterProfile = try await self.pollGeneration(syncMeta, atLeast: 1)
        #expect(afterProfile >= 1)
        try await Task.sleep(for: .milliseconds(300)) // let the re-subscribe settle

        try await self.recordPlay(database, trackID: trackID)
        #expect(try await self.pollGeneration(syncMeta, atLeast: afterProfile + 1) > afterProfile)
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
