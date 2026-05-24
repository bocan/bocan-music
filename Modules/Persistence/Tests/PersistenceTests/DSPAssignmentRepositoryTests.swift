import Foundation
import Testing
@testable import Persistence

@Suite("DSPAssignmentRepository")
struct DSPAssignmentRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func seedTrack(_ db: Database) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        return try await TrackRepository(database: db).insert(
            Track(
                fileURL: "file:///tmp/\(UUID().uuidString).flac",
                fileSize: 1024,
                fileMtime: now,
                fileFormat: "flac",
                duration: 180,
                title: "T",
                addedAt: now,
                updatedAt: now
            )
        )
    }

    private func seedAlbum(_ db: Database) async throws -> Int64 {
        try await AlbumRepository(database: db).insert(Album(title: "A-\(UUID().uuidString)"))
    }

    @Test("track assignment round-trip")
    func trackRoundTrip() async throws {
        let db = try await makeDB()
        let trackID = try await seedTrack(db)
        let repo = DSPAssignmentRepository(database: db)
        try await repo.setTrackPreset(trackID: trackID, presetID: "bocan.rock")
        #expect(try await repo.fetchTrackPresetID(trackID: trackID) == "bocan.rock")
    }

    @Test("setTrackPreset replaces existing assignment")
    func trackUpsert() async throws {
        let db = try await makeDB()
        let trackID = try await seedTrack(db)
        let repo = DSPAssignmentRepository(database: db)
        try await repo.setTrackPreset(trackID: trackID, presetID: "bocan.flat")
        try await repo.setTrackPreset(trackID: trackID, presetID: "bocan.bass")
        #expect(try await repo.fetchTrackPresetID(trackID: trackID) == "bocan.bass")
    }

    @Test("clearTrackPreset removes assignment")
    func clearTrack() async throws {
        let db = try await makeDB()
        let trackID = try await seedTrack(db)
        let repo = DSPAssignmentRepository(database: db)
        try await repo.setTrackPreset(trackID: trackID, presetID: "bocan.rock")
        try await repo.clearTrackPreset(trackID: trackID)
        #expect(try await repo.fetchTrackPresetID(trackID: trackID) == nil)
    }

    @Test("album assignment round-trip + upsert + clear")
    func albumLifecycle() async throws {
        let db = try await makeDB()
        let albumID = try await seedAlbum(db)
        let repo = DSPAssignmentRepository(database: db)
        try await repo.setAlbumPreset(albumID: albumID, presetID: "bocan.classical")
        #expect(try await repo.fetchAlbumPresetID(albumID: albumID) == "bocan.classical")
        try await repo.setAlbumPreset(albumID: albumID, presetID: "bocan.vocal")
        #expect(try await repo.fetchAlbumPresetID(albumID: albumID) == "bocan.vocal")
        try await repo.clearAlbumPreset(albumID: albumID)
        #expect(try await repo.fetchAlbumPresetID(albumID: albumID) == nil)
    }

    @Test("resolvePresetID prefers track over album")
    func resolveTrackWins() async throws {
        let db = try await makeDB()
        let trackID = try await seedTrack(db)
        let albumID = try await seedAlbum(db)
        let repo = DSPAssignmentRepository(database: db)
        try await repo.setTrackPreset(trackID: trackID, presetID: "bocan.track")
        try await repo.setAlbumPreset(albumID: albumID, presetID: "bocan.album")
        #expect(try await repo.resolvePresetID(trackID: trackID, albumID: albumID) == "bocan.track")
    }

    @Test("resolvePresetID falls back to album when no track assignment")
    func resolveAlbumFallback() async throws {
        let db = try await makeDB()
        let trackID = try await seedTrack(db)
        let albumID = try await seedAlbum(db)
        let repo = DSPAssignmentRepository(database: db)
        try await repo.setAlbumPreset(albumID: albumID, presetID: "bocan.album")
        #expect(try await repo.resolvePresetID(trackID: trackID, albumID: albumID) == "bocan.album")
    }

    @Test("resolvePresetID returns nil when no assignments and nil albumID")
    func resolveNoneNoAlbum() async throws {
        let db = try await makeDB()
        let trackID = try await seedTrack(db)
        let repo = DSPAssignmentRepository(database: db)
        #expect(try await repo.resolvePresetID(trackID: trackID, albumID: nil) == nil)
    }

    @Test("resolvePresetID returns nil when nothing is assigned")
    func resolveNone() async throws {
        let db = try await makeDB()
        let trackID = try await seedTrack(db)
        let albumID = try await seedAlbum(db)
        let repo = DSPAssignmentRepository(database: db)
        #expect(try await repo.resolvePresetID(trackID: trackID, albumID: albumID) == nil)
    }
}
