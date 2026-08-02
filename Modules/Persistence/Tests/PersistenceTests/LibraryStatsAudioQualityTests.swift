import Foundation
import Testing
@testable import Persistence

/// The Audio Quality report queries (#373, phase 24), split from the summary
/// and hygiene suite so each test file stays within the type-length budget.
@Suite("LibraryStatsRepository audio quality")
struct LibraryStatsAudioQualityTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    /// Quality fields for one seeded track.
    private struct QualityTrackSpec {
        var format = "flac"
        var lossless: Bool?
        var bytes: Int64 = 100
        var bitrate: Int?
        var sampleRate: Int?
        var bitDepth: Int?
        var peak: Double?
        var suspected: Bool?
        var confidence: Double?
        var shelfHz: Int?
        var analysedAt: Int64?
    }

    /// Seeds one album fronted by `artistName` whose tracks carry the given
    /// quality fields, returning the album id.
    private func seedQualityAlbum(
        _ db: Database,
        title: String,
        artistName: String,
        tracks: [QualityTrackSpec]
    ) async throws -> Int64 {
        try await db.write { db in
            var artist = Artist(name: artistName)
            try artist.insert(db)
            var album = Album(title: title, albumArtistID: artist.id)
            try album.insert(db)
            let albumID = try #require(album.id)
            for (index, spec) in tracks.enumerated() {
                var t = Track(
                    fileURL: "file:///tmp/\(title)-\(index).\(spec.format)",
                    fileSize: spec.bytes,
                    fileMtime: 0,
                    fileFormat: spec.format,
                    duration: 60,
                    title: "\(title) \(index + 1)",
                    addedAt: 0,
                    updatedAt: 0
                )
                t.artistID = artist.id
                t.albumID = albumID
                t.trackNumber = index + 1
                t.isLossless = spec.lossless
                t.bitrate = spec.bitrate
                t.sampleRate = spec.sampleRate
                t.bitDepth = spec.bitDepth
                t.replaygainTrackPeak = spec.peak
                t.provenanceSuspected = spec.suspected
                t.provenanceConfidence = spec.confidence
                t.provenanceShelfHz = spec.shelfHz
                t.provenanceAnalysedAt = spec.analysedAt
                try t.insert(db)
            }
            return albumID
        }
    }

    @Test("fetchAudioQuality splits lossless and lossy by count and bytes")
    func qualityLosslessSplit() async throws {
        let db = try await makeDB()
        _ = try await self.seedQualityAlbum(db, title: "Mixed Bag", artistName: "Q", tracks: [
            .init(lossless: true, bytes: 100, sampleRate: 44100, bitDepth: 16, peak: 0.9),
            .init(lossless: true, bytes: 200, sampleRate: 96000, bitDepth: 24),
            .init(format: "mp3", lossless: false, bytes: 10, bitrate: 320, sampleRate: 44100, peak: 0.8),
            .init(format: "wv", bytes: 5),
        ])

        let report = try await LibraryStatsRepository(database: db).fetchAudioQuality()
        #expect(report.losslessCount == 2)
        #expect(report.lossyCount == 1)
        #expect(report.unknownCount == 1)
        #expect(report.losslessBytes == 300)
        #expect(report.lossyBytes == 10)
        #expect(report.unknownBytes == 5)
        #expect(report.formats.first?.format == "flac")
        #expect(report.formats.first?.count == 2)
        #expect(report.formats.first?.bytes == 300)
        #expect(report.sampleRates.first?.value == 44100)
        #expect(report.lossyBitrates == [.init(value: 320, count: 1)])
    }

    @Test("fetchAudioQuality flags mixed-format albums, single-format pass")
    func qualityMixedFormatAlbums() async throws {
        let db = try await makeDB()
        let mixedID = try await self.seedQualityAlbum(db, title: "Patched", artistName: "M", tracks: [
            .init(lossless: true, sampleRate: 44100, bitDepth: 16),
            .init(format: "mp3", lossless: false, bytes: 10, bitrate: 192, sampleRate: 44100),
        ])
        _ = try await self.seedQualityAlbum(db, title: "Uniform", artistName: "U", tracks: [
            .init(lossless: true, sampleRate: 44100, bitDepth: 16),
            .init(lossless: true, sampleRate: 44100, bitDepth: 16),
        ])

        let report = try await LibraryStatsRepository(database: db).fetchAudioQuality()
        #expect(report.mixedFormatAlbumCount == 1)
        #expect(report.mixedFormatAlbums.first?.id == mixedID)
        #expect(report.mixedFormatAlbums.first?.albumTitle == "Patched")
        #expect(report.mixedFormatAlbums.first?.formats == ["flac", "mp3"])
    }

    @Test("fetchAudioQuality reports true-peak overs and the unanalysed gap")
    func qualityTruePeakOvers() async throws {
        let db = try await makeDB()
        let albumID = try await self.seedQualityAlbum(db, title: "Loud", artistName: "L", tracks: [
            .init(lossless: true, sampleRate: 44100, bitDepth: 16, peak: 1.12),
            .init(lossless: true, sampleRate: 44100, bitDepth: 16, peak: 0.95),
            .init(lossless: true, sampleRate: 44100, bitDepth: 16),
        ])

        let report = try await LibraryStatsRepository(database: db).fetchAudioQuality()
        #expect(report.truePeakOverCount == 1)
        #expect(report.truePeakOvers.first?.truePeakLinear == 1.12)
        #expect(report.truePeakOvers.first?.albumID == albumID)
        #expect(report.unanalysedTrackCount == 1)
    }

    @Test("fetchAudioQuality reports suspected transcodes, highest confidence first")
    func qualitySuspectedTranscodes() async throws {
        let db = try await makeDB()
        let albumID = try await self.seedQualityAlbum(db, title: "Dubious", artistName: "D", tracks: [
            .init(lossless: true, suspected: true, confidence: 0.7, shelfHz: 19000, analysedAt: 100),
            .init(lossless: true, suspected: true, confidence: 0.95, shelfHz: 16000, analysedAt: 100),
            .init(lossless: true, suspected: false, confidence: 0, analysedAt: 100),
            .init(lossless: true),
            .init(format: "mp3", lossless: false, bitrate: 128),
        ])

        let report = try await LibraryStatsRepository(database: db).fetchAudioQuality()
        // Coverage counts are scoped to lossless tracks: 3 analysed, 1 not.
        #expect(report.provenanceAnalysedCount == 3)
        #expect(report.provenanceUnanalysedCount == 1)
        #expect(report.suspectedTranscodeCount == 2)
        #expect(report.suspectedTranscodes.count == 2)
        #expect(report.suspectedTranscodes.first?.confidence == 0.95)
        #expect(report.suspectedTranscodes.first?.shelfFrequencyHz == 16000)
        #expect(report.suspectedTranscodes.first?.albumID == albumID)
        #expect(report.suspectedTranscodes.first?.albumTitle == "Dubious")
    }
}
