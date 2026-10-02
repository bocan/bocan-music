import Foundation
import Metadata
import Persistence
import Testing
@testable import Library

@Suite("TrackImporter compilation grouping and rescan carry-over")
struct TrackImporterRescanTests: TrackImporterFixtures {
    // MARK: - Compilation grouping (#362)

    @Test("compilation with no album-artist groups under one Various Artists album (#362)")
    func compilationGroupsUnderVariousArtists() async throws {
        let db = try await makeDB()
        let importer = self.makeImporter(db)

        for (i, artist) in ["Artist A", "Artist B", "Artist C"].enumerated() {
            _ = try await importer.importTrack(
                url: URL(fileURLWithPath: "/tmp/comp\(i).mp3"),
                bookmark: nil,
                tags: self.compilationTags(artist: artist),
                fileMtime: 1000,
                fileSize: 100
            )
        }

        let albums = try await AlbumRepository(database: db).fetchAll()
        #expect(albums.count == 1)
        #expect(albums.first?.albumArtistID == nil) // nil => "Various Artists"
    }

    @Test("non-compilation with no album-artist still splits by track artist")
    func nonCompilationSplitsByArtist() async throws {
        let db = try await makeDB()
        let importer = self.makeImporter(db)

        for (i, artist) in ["Artist A", "Artist B", "Artist C"].enumerated() {
            _ = try await importer.importTrack(
                url: URL(fileURLWithPath: "/tmp/split\(i).mp3"),
                bookmark: nil,
                tags: self.compilationTags(artist: artist, compilation: false),
                fileMtime: 1000,
                fileSize: 100
            )
        }

        let albums = try await AlbumRepository(database: db).fetchAll()
        #expect(albums.count == 3)
    }

    @Test("explicit album-artist wins over the compilation flag")
    func explicitAlbumArtistWinsOverCompilation() async throws {
        let db = try await makeDB()
        let importer = self.makeImporter(db)

        for (i, artist) in ["Artist A", "Artist B"].enumerated() {
            var tags = self.compilationTags(artist: artist)
            tags.albumArtist = "The Curator"
            _ = try await importer.importTrack(
                url: URL(fileURLWithPath: "/tmp/curated\(i).mp3"),
                bookmark: nil,
                tags: tags,
                fileMtime: 1000,
                fileSize: 100
            )
        }

        let albums = try await AlbumRepository(database: db).fetchAll()
        #expect(albums.count == 1)
        let curator = try await ArtistRepository(database: db).fetchAll()
            .first { $0.name == "The Curator" }
        #expect(albums.first?.albumArtistID == curator?.id)
        #expect(albums.first?.albumArtistID != nil)
    }

    // MARK: - Provenance carry-over (ADR-075 slice 2)

    @Test("re-importing keeps AcoustID, skip-after, computed ReplayGain and the content hash (#423)")
    func reimportPreservesComputedAndUserState() async throws {
        let db = try await makeDB()
        let trackRepo = TrackRepository(database: db)
        let importer = TrackImporter(
            artistRepo: ArtistRepository(database: db),
            albumRepo: AlbumRepository(database: db),
            trackRepo: trackRepo,
            lyricsRepo: LyricsRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db)
        )
        let url = URL(fileURLWithPath: "/tmp/state.flac")
        let id = try await importer.importTrack(
            url: url, bookmark: nil, tags: self.makeTags(title: "State"), fileMtime: 1000, fileSize: 100
        )

        // State the app or the user set after import; none of it lives in tags.
        var row = try await trackRepo.fetch(id: id)
        row.acoustidFingerprint = "AQADtEmSJ"
        row.acoustidID = "acoustid-1"
        row.skipAfterSeconds = 42
        row.replaygainTrackGain = -6.5
        row.replaygainTrackPeak = 0.98
        row.contentHash = "sha-1"
        try await trackRepo.update(row)

        // Full rescan of the unchanged file: tags carry no ReplayGain.
        _ = try await importer.importTrack(
            url: url, bookmark: nil, tags: self.makeTags(title: "State"), fileMtime: 1000, fileSize: 100
        )
        row = try await trackRepo.fetch(id: id)
        #expect(row.acoustidFingerprint == "AQADtEmSJ")
        #expect(row.acoustidID == "acoustid-1")
        #expect(row.skipAfterSeconds == 42)
        #expect(row.replaygainTrackGain == -6.5)
        #expect(row.replaygainTrackPeak == 0.98)
        #expect(row.contentHash == "sha-1")

        // A tag value wins over the computed one.
        var tagged = self.makeTags(title: "State")
        tagged.replayGain = ReplayGain(trackGain: -3.0)
        _ = try await importer.importTrack(url: url, bookmark: nil, tags: tagged, fileMtime: 1000, fileSize: 100)
        row = try await trackRepo.fetch(id: id)
        #expect(row.replaygainTrackGain == -3.0)
        #expect(row.replaygainTrackPeak == 0.98, "peak had no tag, computed value stays")

        // The file changed on disk: the content hash is stale, everything else survives.
        _ = try await importer.importTrack(
            url: url, bookmark: nil, tags: self.makeTags(title: "State"), fileMtime: 2000, fileSize: 120
        )
        row = try await trackRepo.fetch(id: id)
        #expect(row.contentHash == nil)
        #expect(row.acoustidID == "acoustid-1")
        #expect(row.skipAfterSeconds == 42)
    }

    @Test("re-importing an unchanged file keeps its provenance verdict")
    func provenanceSurvivesUnchangedReimport() async throws {
        let db = try await makeDB()
        let trackRepo = TrackRepository(database: db)
        let url = URL(fileURLWithPath: "/tmp/provenance-keep.flac")

        let id = try await self.makeImporter(db).importTrack(
            url: url,
            bookmark: nil,
            tags: self.makeTags(),
            fileMtime: 1000,
            fileSize: 100
        )
        try await trackRepo.setProvenance(
            trackID: id,
            suspected: true,
            confidence: 0.9,
            shelfHz: 16000,
            analysedAt: 2000
        )

        _ = try await self.makeImporter(db).importTrack(
            url: url,
            bookmark: nil,
            tags: self.makeTags(),
            fileMtime: 1000,
            fileSize: 100
        )

        let track = try await trackRepo.fetch(id: id)
        #expect(track.provenanceSuspected == true)
        #expect(track.provenanceConfidence == 0.9)
        #expect(track.provenanceShelfHz == 16000)
        #expect(track.provenanceAnalysedAt == 2000)
    }

    @Test("re-importing a changed file nulls its provenance verdict")
    func provenanceClearedOnChangedFile() async throws {
        let db = try await makeDB()
        let trackRepo = TrackRepository(database: db)
        let url = URL(fileURLWithPath: "/tmp/provenance-drop.flac")

        let id = try await self.makeImporter(db).importTrack(
            url: url,
            bookmark: nil,
            tags: self.makeTags(),
            fileMtime: 1000,
            fileSize: 100
        )
        try await trackRepo.setProvenance(
            trackID: id,
            suspected: true,
            confidence: 0.9,
            shelfHz: 16000,
            analysedAt: 2000
        )

        _ = try await self.makeImporter(db).importTrack(
            url: url,
            bookmark: nil,
            tags: self.makeTags(),
            fileMtime: 3000,
            fileSize: 100
        )

        let track = try await trackRepo.fetch(id: id)
        #expect(track.provenanceSuspected == nil)
        #expect(track.provenanceConfidence == nil)
        #expect(track.provenanceShelfHz == nil)
        #expect(track.provenanceAnalysedAt == nil)
    }

    @Test("a changed file nulls the verdict even when user-edited tags are preserved")
    func provenanceClearedOnUserEditedChangedFile() async throws {
        let db = try await makeDB()
        let trackRepo = TrackRepository(database: db)
        let url = URL(fileURLWithPath: "/tmp/provenance-edited.flac")

        let id = try await self.makeImporter(db).importTrack(
            url: url,
            bookmark: nil,
            tags: self.makeTags(),
            fileMtime: 1000,
            fileSize: 100
        )
        var edited = try await trackRepo.fetch(id: id)
        edited.userEdited = true
        edited.provenanceSuspected = false
        edited.provenanceConfidence = 0
        edited.provenanceAnalysedAt = 2000
        try await trackRepo.update(edited)

        _ = try await self.makeImporter(db).importTrack(
            url: url,
            bookmark: nil,
            tags: self.makeTags(),
            fileMtime: 3000,
            fileSize: 100
        )

        let track = try await trackRepo.fetch(id: id)
        #expect(track.userEdited, "the user-edited skip branch must have handled this import")
        #expect(track.provenanceSuspected == nil)
        #expect(track.provenanceAnalysedAt == nil)
    }
}
