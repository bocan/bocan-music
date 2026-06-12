import Foundation
import Library
import Persistence
import Testing
@testable import UI

// MARK: - PlaylistQueueSyncTests

/// Covers the playlist-queue synchronisation feature: when a manual playlist
/// that is currently playing is edited, the Up Next queue mirrors the change.
@Suite("PlaylistQueueSync")
@MainActor
struct PlaylistQueueSyncTests {
    // MARK: - Helpers

    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func insertTrack(id: String, db: Database) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        let track = Track(
            fileURL: "file:///tmp/\(id).mp3",
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "mp3",
            duration: 180,
            title: id,
            addedAt: now,
            updatedAt: now
        )
        return try await TrackRepository(database: db).insert(track)
    }

    // MARK: - activePlaylistID lifecycle

    @Test("play(tracks:fromPlaylistID:) sets activePlaylistID")
    func activePlaylistIDSetOnPlay() async throws {
        let db = try await self.makeDB()
        let vm = LibraryViewModel(database: db, engine: MockTransport())
        let service = PlaylistService(database: db)
        let playlist = try await service.create(name: "Sync Test")
        guard let pid = playlist.id else { Issue.record("playlist missing id")
            return
        }

        await vm.play(tracks: [], fromPlaylistID: pid)
        #expect(vm.activePlaylistID == pid)
    }

    @Test("stopPlaylistSync clears activePlaylistID and cancels the task")
    func stopClearsState() async throws {
        let db = try await self.makeDB()
        let vm = LibraryViewModel(database: db, engine: MockTransport())
        let service = PlaylistService(database: db)
        let playlist = try await service.create(name: "Stop Test")
        guard let pid = playlist.id else { Issue.record("playlist missing id")
            return
        }

        await vm.play(tracks: [], fromPlaylistID: pid)
        vm.stopPlaylistSync()
        #expect(vm.activePlaylistID == nil)
        #expect(vm.playlistSyncTask == nil)
    }

    @Test("play(tracks:startingAt:shuffle:) clears activePlaylistID via stopPlaylistSync")
    func genericPlayStopsSync() async throws {
        let db = try await self.makeDB()
        let vm = LibraryViewModel(database: db, engine: MockTransport())
        let service = PlaylistService(database: db)
        let playlist = try await service.create(name: "Clear Test")
        guard let pid = playlist.id else { Issue.record("playlist missing id")
            return
        }

        await vm.play(tracks: [], fromPlaylistID: pid)
        #expect(vm.activePlaylistID == pid)

        await vm.play(tracks: [], startingAt: 0)
        #expect(vm.activePlaylistID == nil)
    }

    @Test("clearQueue clears activePlaylistID")
    func clearQueueStopsSync() async throws {
        let db = try await self.makeDB()
        let vm = LibraryViewModel(database: db, engine: MockTransport())
        let service = PlaylistService(database: db)
        let playlist = try await service.create(name: "Clear Queue Test")
        guard let pid = playlist.id else { Issue.record("playlist missing id")
            return
        }

        await vm.play(tracks: [], fromPlaylistID: pid)
        await vm.clearQueue()
        #expect(vm.activePlaylistID == nil)
    }

    @Test("playing a second playlist replaces the active playlist ID")
    func playingSecondPlaylistReplaces() async throws {
        let db = try await self.makeDB()
        let vm = LibraryViewModel(database: db, engine: MockTransport())
        let service = PlaylistService(database: db)
        let p1 = try await service.create(name: "First")
        let p2 = try await service.create(name: "Second")
        guard let pid1 = p1.id, let pid2 = p2.id else { Issue.record("missing ids")
            return
        }

        await vm.play(tracks: [], fromPlaylistID: pid1)
        #expect(vm.activePlaylistID == pid1)

        await vm.play(tracks: [], fromPlaylistID: pid2)
        #expect(vm.activePlaylistID == pid2)
    }

    // MARK: - Source conventions

    private var uiSourcesURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    @Test("PlaylistDetailView.playAll calls play(tracks:fromPlaylistID:startingAt:)")
    func playAllUsesPlaylistID() throws {
        let url = self.uiSourcesURL.appendingPathComponent("Playlists/PlaylistDetailView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("fromPlaylistID: self.playlistID"), "playAll should call play(tracks:fromPlaylistID:)")
    }

    @Test("play(tracks:startingAt:shuffle:) calls stopPlaylistSync() before the QueuePlayer guard")
    func genericPlayCallsStop() throws {
        let url = self.uiSourcesURL.appendingPathComponent("ViewModels/LibraryViewModel.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        // Verify stopPlaylistSync appears before the first QueuePlayer guard in the file
        // (i.e. the method that replaces the queue calls stop before doing anything).
        let stopRange = source.range(of: "stopPlaylistSync()")
        let guardRange = source.range(of: "guard let qp = engine as? QueuePlayer else { return }")
        #expect(stopRange != nil, "LibraryViewModel must contain stopPlaylistSync()")
        #expect(guardRange != nil, "LibraryViewModel must contain a QueuePlayer guard")
        if let sr = stopRange, let gr = guardRange {
            #expect(sr.lowerBound < gr.lowerBound, "stopPlaylistSync must be called before the QueuePlayer guard")
        }
    }
}
