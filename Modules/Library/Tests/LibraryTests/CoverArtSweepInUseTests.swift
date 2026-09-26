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

        // A new cover for a third album. Its sweep runs inside `persist`,
        // before the scan can link it, when it is the only file not in use:
        // 300 KB against 250 KB.
        let third = try #require(try await bed.cache.persist([Self.art(fill: 0xC2)], source: "embedded"))
        let albumThree = try await bed.albums.insert(Album(title: "Three"))
        try await bed.albums.setCoverArt(albumID: albumThree, hash: third.hash, path: third.path)

        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: third.path), "a new cover is not evicted before it is linked")
        #expect(try await bed.repo.fetch(hash: third.hash) != nil)
        #expect(try await bed.albums.fetch(id: albumOne).coverArtHash == first.hash)
        #expect(try await bed.albums.fetch(id: albumTwo).coverArtHash == second.hash)
        #expect(try await bed.albums.fetch(id: albumThree).coverArtHash == third.hash)
    }

    @Test("Art another import has persisted but not linked yet survives the next import's sweep")
    func pendingLinkSurvivesConcurrentImport() async throws {
        let bed = try await Self.makeBed()
        defer { try? FileManager.default.removeItem(at: bed.dir) }
        let first = try await Self.agedEmbedded(bed, fill: 0xE0, age: 0)
        let second = try await Self.agedEmbedded(bed, fill: 0xE1, age: 1000)
        for (fill, art) in [(UInt8(0xE0), first), (UInt8(0xE1), second)] {
            let albumID = try await bed.albums.insert(Album(title: "In Use \(fill)"))
            try await bed.albums.setCoverArt(albumID: albumID, hash: art.hash, path: art.path)
        }

        // A scan imports up to four files at once: one import persists its
        // cover and has not linked it yet when another import persists.
        let pending = try #require(try await bed.cache.persist([Self.art(fill: 0xE2)], source: "embedded"))
        let other = try #require(try await bed.cache.persist([Self.art(fill: 0xE3)], source: "embedded"))

        #expect(FileManager.default.fileExists(atPath: pending.path))
        #expect(try await bed.repo.fetch(hash: pending.hash) != nil, "the import can still link it")
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test("Once its grace period is over, art nothing uses is evicted again")
    func graceEnds() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-art-grace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await Database(location: .inMemory)
        let repo = CoverArtRepository(database: db)
        let cache = CoverArtCache(
            cacheRoot: dir, repo: repo, totalBytesLimit: 250_000, sweepThresholdBytes: 1, newArtGracePeriod: 60
        )
        let unused = try #require(try await cache.persist([Self.art(fill: 0xF0)], source: "embedded"))
        // Written two minutes ago: past the 60 s grace.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: unused.path
        )
        _ = try await cache.persist([Self.art(fill: 0xF1)], source: "embedded")
        _ = try await cache.persist([Self.art(fill: 0xF2)], source: "embedded")

        #expect(!FileManager.default.fileExists(atPath: unused.path))
        #expect(try await repo.fetch(hash: unused.hash) == nil)
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
