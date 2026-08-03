import Foundation
import Testing
@testable import Persistence

/// The Listening Behaviour report queries (#373, phase 25-2), in their own
/// suite like the other report slices to stay within the type-length budget.
@Suite("LibraryStatsRepository listening behaviour")
struct LibraryStatsListeningTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    /// Play state for one seeded track, local and imported.
    private struct ListenTrackSpec {
        var trackNumber: Int?
        var disc: Int?
        var plays = 0
        var skips = 0
        var bail: Double?
        var lastPlayed: Int64?
        var importPlays = 0
        var importLast: Int64?
    }

    @discardableResult
    private func seedAlbum(
        _ db: Database,
        title: String,
        artistName: String,
        tracks: [ListenTrackSpec]
    ) async throws -> Int64 {
        try await db.write { db in
            var artist = Artist(name: artistName)
            try artist.insert(db)
            var album = Album(title: title, albumArtistID: artist.id)
            try album.insert(db)
            let albumID = try #require(album.id)
            for (index, spec) in tracks.enumerated() {
                var track = Track(
                    fileURL: "file:///tmp/\(title)-\(index).flac",
                    fileFormat: "flac",
                    duration: 200,
                    title: "\(title) \(index + 1)",
                    addedAt: 0,
                    updatedAt: 0
                )
                track.artistID = artist.id
                track.albumID = albumID
                track.trackNumber = spec.trackNumber
                track.discNumber = spec.disc
                track.playCount = spec.plays
                track.skipCount = spec.skips
                track.skipAfterSeconds = spec.bail
                track.lastPlayedAt = spec.lastPlayed
                try track.insert(db)
                let trackID = try #require(track.id)
                for play in 0 ..< spec.importPlays {
                    var listen = ImportedListen(
                        playedAt: (spec.importLast ?? 1000) - Int64(play),
                        artist: artistName,
                        title: track.title ?? "",
                        trackID: trackID
                    )
                    try listen.insert(db)
                }
            }
            return albumID
        }
    }

    // MARK: - Gini

    @Test("Gini agrees with hand-computed distributions")
    func giniArithmetic() {
        #expect(LibraryStatsRepository.gini([]) == nil)
        #expect(LibraryStatsRepository.gini([0, 0, 0]) == nil, "nothing played means no coefficient, not zero")
        #expect(LibraryStatsRepository.gini([5, 5, 5, 5]) == 0, "perfectly even rotation")
        #expect(LibraryStatsRepository.gini([7]) == 0)
        let brutal = try? #require(LibraryStatsRepository.gini([0, 0, 0, 4]))
        #expect(abs((brutal ?? 0) - 0.75) < 0.0001, "one track taking every play on four tracks is 0.75")
    }

    // MARK: - Utilisation

    @Test("Utilisation counts lifetime plays, local or imported")
    func utilisationCountsLifetime() async throws {
        let db = try await makeDB()
        try await self.seedAlbum(db, title: "Mixed", artistName: "U", tracks: [
            .init(trackNumber: 1, plays: 2),
            .init(trackNumber: 2, importPlays: 1),
            .init(trackNumber: 3),
        ])
        let report = try await LibraryStatsRepository(database: db).fetchListeningBehaviour()
        #expect(report.trackCount == 3)
        #expect(report.playedTrackCount == 2, "an import-only play still counts as ever played")
        let gini = try #require(report.giniCoefficient)
        // Lifetime counts [2, 1, 0] -> 4/9.
        #expect(abs(gini - 4.0 / 9.0) < 0.0001)
    }

    // MARK: - Skip candidates

    @Test("Skip candidates need three skips and more skips than plays, worst first")
    func skipCandidatesFilterAndOrder() async throws {
        let db = try await makeDB()
        try await self.seedAlbum(db, title: "Skips", artistName: "S", tracks: [
            .init(trackNumber: 1, plays: 1, skips: 5, bail: 42),
            .init(trackNumber: 2, plays: 0, skips: 4),
            .init(trackNumber: 3, plays: 1, skips: 2),
            .init(trackNumber: 4, plays: 5, skips: 3),
        ])
        let report = try await LibraryStatsRepository(database: db).fetchListeningBehaviour()
        #expect(report.skipCandidateCount == 2)
        #expect(report.skipCandidates.count == 2)
        let worst = try #require(report.skipCandidates.first)
        #expect(worst.trackTitle == "Skips 2", "a 100% skip rate outranks five skips at 83%")
        #expect(worst.skipRate == 1.0)
        #expect(report.skipCandidates[1].averageBailSeconds == 42)
        #expect(report.skipCandidates[1].skipRate == 5.0 / 6.0)
    }

    // MARK: - Dormant favourites

    @Test("Dormant favourites need lifetime plays and two years of silence")
    func dormantFavourites() async throws {
        let db = try await makeDB()
        let now = Int64(Date().timeIntervalSince1970)
        let old = now - 100_000_000
        let recent = now - 1000
        try await self.seedAlbum(db, title: "Dormant", artistName: "D", tracks: [
            .init(trackNumber: 1, plays: 12, lastPlayed: old),
            .init(trackNumber: 2, plays: 12, lastPlayed: recent),
            .init(trackNumber: 3, plays: 3, lastPlayed: old),
            .init(trackNumber: 4, importPlays: 10, importLast: old),
            .init(trackNumber: 5, plays: 12, lastPlayed: old, importPlays: 1, importLast: recent),
        ])
        let report = try await LibraryStatsRepository(database: db).fetchListeningBehaviour()
        #expect(report.dormantFavouriteCount == 2)
        #expect(report.dormantFavourites.map(\.trackTitle) == ["Dormant 1", "Dormant 4"])
        #expect(
            report.dormantFavourites.first?.lifetimePlays == 12,
            "track 5's recent imported listen must disqualify it, not re-rank it"
        )
    }

    // MARK: - Abandoned albums

    @Test("Abandoned albums stopped inside the leading tracks of a real album")
    func abandonedAlbums() async throws {
        let db = try await makeDB()
        func specs(_ count: Int, playedThrough: Int, importOnly: Bool = false) -> [ListenTrackSpec] {
            (1 ... count).map { number in
                var spec = ListenTrackSpec(trackNumber: number)
                if number <= playedThrough {
                    if importOnly {
                        spec.importPlays = 1
                    } else {
                        spec.plays = 1
                    }
                }
                return spec
            }
        }
        let byPlays = try await self.seedAlbum(db, title: "Stalled", artistName: "A1", tracks: specs(8, playedThrough: 2))
        _ = try await self.seedAlbum(db, title: "Finished", artistName: "A2", tracks: specs(8, playedThrough: 5))
        _ = try await self.seedAlbum(db, title: "Untouched", artistName: "A3", tracks: specs(8, playedThrough: 0))
        _ = try await self.seedAlbum(db, title: "Tiny", artistName: "A4", tracks: specs(5, playedThrough: 2))
        let byImport = try await self.seedAlbum(
            db,
            title: "Stalled Import",
            artistName: "A5",
            tracks: specs(8, playedThrough: 1, importOnly: true)
        )
        var boxSet = specs(8, playedThrough: 2)
        boxSet[7].disc = 2
        _ = try await self.seedAlbum(db, title: "Box Set", artistName: "A6", tracks: boxSet)

        let report = try await LibraryStatsRepository(database: db).fetchListeningBehaviour()
        #expect(report.abandonedAlbumCount == 2)
        #expect(Set(report.abandonedAlbums.map(\.id)) == [byPlays, byImport])
        let stalled = try #require(report.abandonedAlbums.first { $0.id == byPlays })
        #expect(stalled.playedThroughTrack == 2)
        #expect(stalled.trackCount == 8)
    }
}
