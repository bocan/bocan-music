import Foundation
import Metadata
import Persistence
import Testing
@testable import Library

/// #576: the `CoverArt/` size sweep must not evict art an album or a track
/// still shows. Eviction deletes the `cover_art` row, `ON DELETE SET NULL`
/// clears the links, and a quick scan skips every unchanged file
/// (`ChangeDetector.check`), so the cover stayed gone until a full rescan.
/// The sweep now evicts only art nothing uses, and lets the folder stay over
/// budget when everything left is in use.
///
/// Budget: two arts of 100 KB. Persisting a third forces a sweep.
@Suite("CoverArtCache sweep and art albums and tracks still use")
struct CoverArtSweepInUseTests {
    private static let artBytes = 100_000
    private static let longAgo = Date(timeIntervalSince1970: 1_600_000_000)

    private struct Bed {
        let dir: URL
        let db: Database
        let repo: CoverArtRepository
        let albums: AlbumRepository
        let tracks: TrackRepository
        let cache: CoverArtCache
    }

    private static func makeBed() async throws -> Bed {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-art-in-use-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try await Database(location: .inMemory)
        let repo = CoverArtRepository(database: db)
        let cache = CoverArtCache(cacheRoot: dir, repo: repo, totalBytesLimit: 250_000, sweepThresholdBytes: 1)
        return Bed(
            dir: dir,
            db: db,
            repo: repo,
            albums: AlbumRepository(database: db),
            tracks: TrackRepository(database: db),
            cache: cache
        )
    }

    private static func art(fill: UInt8) throws -> ExtractedCoverArt {
        let raw = RawCoverArt(data: Data(repeating: fill, count: Self.artBytes), mimeType: "image/jpeg", pictureType: 3)
        return try #require(CoverArtExtractor.extract(from: [raw]).first)
    }

    /// Embedded art, persisted as a scan would, then aged `age` seconds past
    /// `longAgo`: a lower age is less recently used, so evicted first.
    private static func agedEmbedded(_ bed: Bed, fill: UInt8, age: TimeInterval) async throws -> (hash: String, path: String) {
        let persisted = try #require(try await bed.cache.persist([Self.art(fill: fill)], source: "embedded"))
        let mtime = Self.longAgo.addingTimeInterval(age)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: persisted.path)
        return persisted
    }

    private static func track(albumID: Int64?, coverArtHash: String?) -> Track {
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            fileURL: "/tmp/\(UUID().uuidString).flac",
            fileFormat: "flac",
            duration: 200,
            title: "Song",
            addedAt: now,
            updatedAt: now
        )
        track.albumID = albumID
        track.coverArtHash = coverArtHash
        return track
    }

    @Test("Embedded art an album shows survives a sweep, and the album keeps its cover")
    func albumArtSurvives() async throws {
        let bed = try await Self.makeBed()
        defer { try? FileManager.default.removeItem(at: bed.dir) }
        let albumID = try await bed.albums.insert(Album(title: "Still Showing"))
        // The album's art is the least recently used: the old sweep took it first.
        let shown = try await Self.agedEmbedded(bed, fill: 0xA0, age: 0)
        try await bed.albums.setCoverArt(albumID: albumID, hash: shown.hash, path: shown.path)
        let unused = try await Self.agedEmbedded(bed, fill: 0xA1, age: 1000)

        // 300 KB against 250 KB: the sweep must evict one file.
        _ = try await bed.cache.persist([Self.art(fill: 0xA2)], source: "embedded")

        #expect(FileManager.default.fileExists(atPath: shown.path))
        #expect(try await bed.repo.fetch(hash: shown.hash) != nil)
        #expect(try await bed.albums.fetch(id: albumID).coverArtHash == shown.hash)
        #expect(!FileManager.default.fileExists(atPath: unused.path), "art nothing uses is evicted instead")
        #expect(try await bed.repo.fetch(hash: unused.hash) == nil)
    }

    @Test("Embedded art a track shows survives a sweep, and the track keeps its cover")
    func trackArtSurvives() async throws {
        let bed = try await Self.makeBed()
        defer { try? FileManager.default.removeItem(at: bed.dir) }
        let shown = try await Self.agedEmbedded(bed, fill: 0xB0, age: 0)
        let trackID = try await bed.tracks.insert(Self.track(albumID: nil, coverArtHash: shown.hash))
        let unused = try await Self.agedEmbedded(bed, fill: 0xB1, age: 1000)

        _ = try await bed.cache.persist([Self.art(fill: 0xB2)], source: "embedded")

        #expect(FileManager.default.fileExists(atPath: shown.path))
        #expect(try await bed.tracks.fetch(id: trackID).coverArtHash == shown.hash)
        #expect(!FileManager.default.fileExists(atPath: unused.path))
    }

    @Test("When everything is in use the folder stays over budget and nothing is evicted")
    func everythingInUseStaysOverBudget() async throws {
        let bed = try await Self.makeBed()
        defer { try? FileManager.default.removeItem(at: bed.dir) }
        let first = try await Self.agedEmbedded(bed, fill: 0xC0, age: 0)
        let second = try await Self.agedEmbedded(bed, fill: 0xC1, age: 1000)
        let albumOne = try await bed.albums.insert(Album(title: "One"))
        let albumTwo = try await bed.albums.insert(Album(title: "Two"))
        try await bed.albums.setCoverArt(albumID: albumOne, hash: first.hash, path: first.path)
        try await bed.albums.setCoverArt(albumID: albumTwo, hash: second.hash, path: second.path)

        // A sweep runs inside `persist`, before the new art can be linked, so
        // the third file is art the user chose (#570 keeps it). Every file is
        // then in use or unrebuildable: 300 KB against 250 KB.
        let third = try #require(try await bed.cache.persist([Self.art(fill: 0xC2)], source: "user"))

        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: third.path))
        #expect(try await bed.albums.fetch(id: albumOne).coverArtHash == first.hash)
        #expect(try await bed.albums.fetch(id: albumTwo).coverArtHash == second.hash)
    }

    @Test("The full-size original of art in use can still be evicted: nothing reads it")
    func originalOfArtInUseIsEvictable() async throws {
        let bed = try await Self.makeBed()
        defer { try? FileManager.default.removeItem(at: bed.dir) }
        let albumID = try await bed.albums.insert(Album(title: "Big Cover"))
        let shown = try await Self.agedEmbedded(bed, fill: 0xD0, age: 0)
        try await bed.albums.setCoverArt(albumID: albumID, hash: shown.hash, path: shown.path)
        // `persist` keeps an original only for art over 4096 px; place one by
        // hand, named by the same hash, as it would be.
        let originals = bed.dir.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let original = originals.appendingPathComponent("\(shown.hash).jpg").path
        try Data(repeating: 0xD0, count: Self.artBytes).write(to: URL(fileURLWithPath: original))
        // Newer than the album's art, which the old sweep would take first.
        try FileManager.default.setAttributes(
            [.modificationDate: Self.longAgo.addingTimeInterval(1000)], ofItemAtPath: original
        )

        _ = try await bed.cache.persist([Self.art(fill: 0xD1)], source: "embedded")

        #expect(FileManager.default.fileExists(atPath: shown.path), "the cover the album shows stays")
        #expect(!FileManager.default.fileExists(atPath: original), "its unused full-size copy goes first")
        #expect(try await bed.albums.fetch(id: albumID).coverArtHash == shown.hash)
    }
}
