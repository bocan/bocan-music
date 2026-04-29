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
        let importer = PlaylistImportService(resolver: resolver, playlists: playlistService)
        let report = try await importer.importPayload(payload)
        #expect(report.resolution.matches.count == 3)

        // Verify membership order.
        let members = try await playlistService.tracks(in: report.playlistID)
        let memberIDs = members.compactMap(\.id)
        #expect(memberIDs == [idC, idA, idB])

        // Export and check ordering survives.
        let exporter = PlaylistExportService(database: db)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("rt.m3u8")
        try await exporter.export(.init(playlistID: report.playlistID, destination: dest, format: .m3u8, pathMode: .absolute))
        let body = try String(contentsOf: dest, encoding: .utf8)
        try? FileManager.default.removeItem(at: dest)
        let parsed = try M3UReader.parse(data: Data(body.utf8), sourceURL: dest)
        #expect(parsed.entries.count == 3)
        #expect(parsed.entries[0].path.hasSuffix("c.mp3"))
        #expect(parsed.entries[1].path.hasSuffix("a.mp3"))
        #expect(parsed.entries[2].path.hasSuffix("b.mp3"))
    }
}
