import Foundation
import Testing
@testable import Library
@testable import Persistence

@Suite("TrackResolver / ImportService / ExportService")
struct PlaylistIOIntegrationTests {
    private func makeDB() async throws -> Persistence.Database {
        try await Persistence.Database(location: .inMemory)
    }

    private func insertTrack(
        _ db: Persistence.Database,
        path: String,
        title: String,
        artist: String? = nil,
        duration: Double = 180
    ) async throws -> Int64 {
        let trackRepo = TrackRepository(database: db)
        let now = Int64(Date().timeIntervalSince1970)
        var artistID: Int64?
        if let artist {
            let artistRepo = ArtistRepository(database: db)
            artistID = try await (artistRepo.findOrCreate(name: artist)).id
        }
        let url = URL(fileURLWithPath: path).absoluteString
        let track = Track(
            fileURL: url,
            fileSize: 1,
            fileMtime: now,
            fileFormat: "mp3",
            duration: duration,
            title: title,
            artistID: artistID,
            addedAt: now,
            updatedAt: now
        )
        return try await trackRepo.insert(track)
    }

    @Test("Resolves entries by file URL and by metadata")
    func resolverHits() async throws {
        let db = try await makeDB()
        let id1 = try await insertTrack(db, path: "/Music/a.mp3", title: "Song A", artist: "Artist X")
        let id2 = try await insertTrack(db, path: "/Music/b.mp3", title: "Song B", artist: "Artist Y", duration: 200)

        let resolver = TrackResolver(trackRepo: TrackRepository(database: db))
        let payload = PlaylistPayload(name: "p", entries: [
            // Hit by exact file URL.
            .init(path: "/Music/a.mp3", absoluteURL: URL(fileURLWithPath: "/Music/a.mp3")),
            // Hit by fuzzy artist+title+duration.
            .init(
                path: "missing/path.mp3",
                absoluteURL: nil,
                durationHint: 200,
                titleHint: "Song B",
                artistHint: "Artist Y"
            ),
            // Miss.
            .init(path: "ghost.mp3", absoluteURL: nil),
        ])
        let res = await resolver.resolve(payload)
        #expect(res.matches.count == 2)
        #expect(res.misses.count == 1)
        let matched = Dictionary(uniqueKeysWithValues: res.matches.map { ($0.entryIndex, $0.trackID) })
        #expect(matched[0] == id1)
        #expect(matched[1] == id2)
    }

    /// A temp folder holding a real 2-second MP3 (copied from the fixture
    /// library) and a CUE sheet splitting it at 1s, so the last track's
    /// duration must come from probing the audio file, not from an INDEX.
    private func makeCueFolder() throws -> (cue: URL, dir: URL) {
        let fixture = URL(filePath: #filePath)
            .deletingLastPathComponent() // PlaylistIO/
            .deletingLastPathComponent() // LibraryTests/
            .appendingPathComponent(
                "Fixtures/sample-library/Various Artists/Compilation/01 - Artist F Track.mp3"
            )
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-eof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: dir.appendingPathComponent("album.mp3"))
        let cue = dir.appendingPathComponent("album.cue")
        let sheet = """
        PERFORMER "Sheet Artist"
        TITLE "EOF Album"
        FILE "album.mp3" WAVE
          TRACK 01 AUDIO
            TITLE "First"
            PERFORMER "Track Artist"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Last"
            INDEX 01 00:01:00
        """
        try Data(sheet.utf8).write(to: cue)
        return (cue, dir)
    }

    private func makeCueImporter(_ db: Persistence.Database) -> PlaylistImportService {
        let trackRepo = TrackRepository(database: db)
        return PlaylistImportService(
            resolver: TrackResolver(trackRepo: trackRepo),
            playlists: PlaylistService(database: db),
            trackRepo: trackRepo,
            radioStations: RadioStationRepository(database: db),
            cueMarkers: CueMarkerService(
                trackRepo: trackRepo,
                markerRepo: TrackMarkerRepository(database: db)
            )
        )
    }

    @Test("CUE import attaches markers to the indexed track and resolves a playlist (ADR-087)")
    func cueImportAttachesMarkers() async throws {
        let (cue, dir) = try self.makeCueFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        let db = try await makeDB()
        let audioPath = dir.appendingPathComponent("album.mp3").path
        let trackID = try await insertTrack(db, path: audioPath, title: "Album", artist: "Sheet Artist")

        let importer = self.makeCueImporter(db)
        let report = try await importer.importFile(at: cue)

        // Markers: two cue TRACKs on one FILE, chapters-model attach.
        let markers = try await TrackMarkerRepository(database: db).markers(forTrack: trackID)
        #expect(markers.count == 2)
        #expect(markers[0].title == "First")
        #expect(markers[0].positionMs == 0)
        #expect(markers[0].performer == "Track Artist")
        #expect(markers[1].title == "Last")
        #expect(markers[1].positionMs == 1000)
        #expect(markers[1].performer == "Sheet Artist", "sheet PERFORMER is the fallback")

        // Playlist: the FILE entry resolves to the real track; no virtual rows.
        let playlistID = try #require(report.playlistID)
        let members = try await PlaylistService(database: db).tracks(in: playlistID)
        #expect(members.compactMap(\.id) == [trackID])
        let virtual = try await TrackRepository(database: db)
            .fetchOne(fileURL: URL(fileURLWithPath: audioPath).absoluteString + "?cue=1")
        #expect(virtual == nil, "the virtual-track model is retired")
    }

    @Test("a one-FILE-per-track manifest cue attaches no markers (ADR-087 inertness)")
    func manifestCueIsInert() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["01 - One.mp3", "02 - Two.mp3"] {
            try Data([0x01]).write(to: dir.appendingPathComponent(name))
        }
        let sheet = """
        TITLE "Manifest Album"
        FILE "01 - One.mp3" WAVE
          TRACK 01 AUDIO
            TITLE "One"
            INDEX 01 00:00:00
        FILE "02 - Two.mp3" WAVE
          TRACK 02 AUDIO
            TITLE "Two"
            INDEX 01 00:00:00
        """
        let cue = dir.appendingPathComponent("manifest.cue")
        try Data(sheet.utf8).write(to: cue)

        let db = try await makeDB()
        let id1 = try await insertTrack(db, path: dir.appendingPathComponent("01 - One.mp3").path, title: "One")
        let id2 = try await insertTrack(db, path: dir.appendingPathComponent("02 - Two.mp3").path, title: "Two")

        // Pre-seed phantom markers on one track (the gaps-appended parser
        // bug minted these on real libraries): the attach must clear them.
        let repo = TrackMarkerRepository(database: db)
        try await repo.replaceMarkers(forTrack: id1, with: [
            TrackMarker(trackID: id1, positionMs: 0, title: "Phantom"),
            TrackMarker(trackID: id1, positionMs: 1000, title: "Phantom 2"),
        ])

        let importer = self.makeCueImporter(db)
        let report = try await importer.importFile(at: cue)

        // No markers anywhere: single-marker sets are inert by construction,
        // and stale phantom markers heal on re-attach.
        #expect(try await repo.markers(forTrack: id1).isEmpty)
        #expect(try await repo.markers(forTrack: id2).isEmpty)

        // The playlist still resolves both real tracks in sheet order.
        let playlistID = try #require(report.playlistID)
        let members = try await PlaylistService(database: db).tracks(in: playlistID)
        #expect(members.compactMap(\.id) == [id1, id2])
    }

    @Test("cueAudioNeedingAccess flags unreadable audio, stays quiet for readable (#391)")
    func cueAccessProbe() async throws {
        let (cue, dir) = try self.makeCueFolder()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("album.mp3").path
            )
            try? FileManager.default.removeItem(at: dir)
        }
        let db = try await makeDB()
        let importer = self.makeCueImporter(db)

        // Readable audio: no prompt warranted.
        let quiet = await importer.cueAudioNeedingAccess(at: cue)
        #expect(quiet.isEmpty)

        // Unreadable audio (chmod 0): flagged. Root-scope coverage cannot be
        // simulated in a non-sandboxed test process (a bookmark scope cannot
        // defeat POSIX permissions), so the root-covered branch is exercised
        // structurally by the sheet convention test instead.
        let audio = dir.appendingPathComponent("album.mp3")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: audio.path)
        let blocked = await importer.cueAudioNeedingAccess(at: cue)
        #expect(blocked.map(\.lastPathComponent) == ["album.mp3"])
    }

    @Test("Import + Export round-trip preserves order")
    func importExportRoundtrip() async throws {
        let db = try await makeDB()
        let idA = try await insertTrack(db, path: "/m/a.mp3", title: "A", artist: "X")
        let idB = try await insertTrack(db, path: "/m/b.mp3", title: "B", artist: "Y")
        let idC = try await insertTrack(db, path: "/m/c.mp3", title: "C", artist: "Z")

        let payload = PlaylistPayload(name: "Mix", entries: [
            .init(path: "/m/c.mp3", absoluteURL: URL(fileURLWithPath: "/m/c.mp3")),
            .init(path: "/m/a.mp3", absoluteURL: URL(fileURLWithPath: "/m/a.mp3")),
            .init(path: "/m/b.mp3", absoluteURL: URL(fileURLWithPath: "/m/b.mp3")),
        ])
        let resolver = TrackResolver(trackRepo: TrackRepository(database: db))
        let playlistService = PlaylistService(database: db)
        let importer = PlaylistImportService(
            resolver: resolver,
            playlists: playlistService,
            trackRepo: TrackRepository(database: db),
            radioStations: RadioStationRepository(database: db)
        )
        let report = try await importer.importPayload(payload)
        #expect(report.resolution.matches.count == 3)
        let playlistID = try #require(report.playlistID)

        // Verify membership order.
        let members = try await playlistService.tracks(in: playlistID)
        let memberIDs = members.compactMap(\.id)
        #expect(memberIDs == [idC, idA, idB])

        // Export and check ordering survives.
        let exporter = PlaylistExportService(database: db)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("rt.m3u8")
        try await exporter.export(.init(playlistID: playlistID, destination: dest, format: .m3u8, pathMode: .absolute))
        let body = try String(contentsOf: dest, encoding: .utf8)
        try? FileManager.default.removeItem(at: dest)
        let parsed = try M3UReader.parse(data: Data(body.utf8), sourceURL: dest)
        #expect(parsed.entries.count == 3)
        #expect(parsed.entries[0].path.hasSuffix("c.mp3"))
        #expect(parsed.entries[1].path.hasSuffix("a.mp3"))
        #expect(parsed.entries[2].path.hasSuffix("b.mp3"))
    }
}
