import Foundation
import GRDB
import Persistence
import Testing
@testable import Library

// MARK: - Fixture

/// The Picard-tagged library from `Scripts/gen-picard-fixtures.sh` (issue #420).
private var picardLibraryURL: URL {
    get throws {
        guard let url = Bundle.module.url(forResource: "picard-library", withExtension: nil, subdirectory: "Fixtures") else {
            throw LibraryError.scanAlreadyInProgress
        }
        return url
    }
}

private enum MBID {
    static let kestrels = "11111111-1111-4111-8111-111111111111"
    static let storm = "22222222-2222-4222-8222-222222222222"
    static let soloOne = "33333333-3333-4333-8333-333333333333"
    static let soloTwo = "44444444-4444-4444-8444-444444444444"
    static let various = "89ad4ac3-39f7-470e-963a-56509c546377"
    static let releaseA = "aaaaaaa1-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
    static let group1 = "aaaaaaa1-0000-4000-8000-000000000001"
    static let releaseB = "bbbbbbb1-bbbb-4bbb-8bbb-bbbbbbbbbbb1"
    static let group2 = "bbbbbbb1-0000-4000-8000-000000000002"
    static let group3 = "ccccccc1-0000-4000-8000-000000000003"
}

/// Scans the fixture into a fresh in-memory library and returns it.
private func scannedLibrary() async throws -> Persistence.Database {
    let db = try await Persistence.Database(location: .inMemory)
    let scanner = LibraryScanner(database: db)
    try await scanner.addRoot(picardLibraryURL)
    var finished = false
    for await event in await scanner.scan(mode: .full) {
        if case .finished = event { finished = true }
    }
    #expect(finished)
    return db
}

// MARK: - Scan then assert rows

@Suite("Picard library scan lands entity rows (#420)")
struct PicardLibraryScanTests {
    @Test("artists get sort names and MusicBrainz ids from tags, or a derived sort name")
    func artistRows() async throws {
        let db = try await scannedLibrary()
        let artists = ArtistRepository(database: db)
        let kestrels = try #require(try await artists.fetchOne(name: "The Kestrels"))
        #expect(kestrels.sortName == "Kestrels, The", "ARTISTSORT tag wins")
        #expect(kestrels.musicbrainzArtistID == MBID.kestrels)

        let storm = try #require(try await artists.fetchOne(name: "A Quiet Storm"))
        #expect(storm.sortName == "Quiet Storm, A", "no tag: derived from the leading article")
        #expect(storm.musicbrainzArtistID == MBID.storm)

        // Track-only artists on a compilation get the track-artist id; the
        // album artist gets the album-artist id.
        #expect(try await artists.fetchOne(name: "Solo One")?.musicbrainzArtistID == MBID.soloOne)
        #expect(try await artists.fetchOne(name: "Solo Two")?.musicbrainzArtistID == MBID.soloTwo)
        #expect(try await artists.fetchOne(name: "Various Artists")?.musicbrainzArtistID == MBID.various)
        #expect(try await artists.fetchOne(name: "Solo One")?.sortName == nil, "no article, no tag: stays NULL")
    }

    @Test("albums get MBIDs, totals, release type and art rolled up from their tracks")
    func albumRows() async throws {
        let db = try await scannedLibrary()
        let albums = try await AlbumRepository(database: db).fetchAll()
        func album(_ title: String) throws -> Album {
            try #require(albums.first { $0.title == title })
        }

        let morning = try album("Morning Light")
        #expect(morning.musicbrainzReleaseID == MBID.releaseA)
        #expect(morning.musicbrainzReleaseGroupID == MBID.group1)
        #expect(morning.totalTracks == 2)
        #expect(morning.totalDiscs == 1)
        #expect(morning.releaseType == "album")
        #expect(morning.year == 2021)
        #expect(morning.coverArtHash != nil, "embedded front cover")

        let harbour = try album("Harbour EP")
        #expect(harbour.musicbrainzReleaseID == MBID.releaseB)
        #expect(harbour.musicbrainzReleaseGroupID == MBID.group2)
        #expect(harbour.totalTracks == 2, "from n/N TRCK and trkn, not TRACKTOTAL")
        #expect(harbour.releaseType == "ep")
        #expect(harbour.coverArtHash != nil, "sidecar cover.jpg")

        let mixed = try album("Mixed Pressing")
        #expect(mixed.musicbrainzReleaseGroupID == MBID.group3)
        #expect(mixed.musicbrainzReleaseID == nil, "two pressings: no single release id")
        #expect(mixed.totalDiscs == 2)
        #expect(mixed.releaseType == "album")
    }

    @Test("tracks get bit depth for lossless only, totals from n/N, and per-track artist ids")
    func trackRows() async throws {
        let db = try await scannedLibrary()
        let tracks = try await db.read { try Track.fetchAll($0) }
        func track(_ title: String) throws -> Track {
            try #require(tracks.first { $0.title == title })
        }

        let kestrel = try track("Kestrel 1")
        #expect(kestrel.bitDepth == 24)
        #expect(kestrel.sampleRate == 96000)
        #expect(kestrel.trackTotal == 2)
        #expect(kestrel.musicbrainzArtistID == MBID.kestrels)
        #expect(kestrel.replaygainTrackGain == -6.5)
        #expect(kestrel.composer == "R. Kestrel")

        let harbour = try track("Harbour")
        #expect(harbour.bitDepth == nil, "lossy: no bit depth")
        #expect(harbour.trackTotal == 2, "TRCK 1/2")
        #expect(harbour.discTotal == 1)
        #expect(try track("Lighthouse").trackTotal == 2, "trkn 2/2")
        #expect(try track("Solo One Song").bitDepth == 16)
        #expect(try track("Solo Two Song").bitDepth == nil)
        #expect(try track("Solo Two Song").discNumber == 2)
    }

    @Test("cover_art rows carry dimensions, size and provenance")
    func coverArtRows() async throws {
        let db = try await scannedLibrary()
        let rows = try await db.read { try CoverArt.fetchAll($0) }
        let sources = Set(rows.compactMap(\CoverArt.source))
        #expect(sources == ["embedded", "sidecar"])
        let embedded = try #require(rows.first { $0.source == "embedded" })
        #expect(embedded.width == 600)
        #expect(embedded.height == 600)
        #expect((embedded.byteSize ?? 0) > 0)
        let sidecar = try #require(rows.first { $0.source == "sidecar" })
        #expect(sidecar.width == 300)
    }
}

// MARK: - Column population guard

@Suite("Column population guard (#420)")
struct ColumnPopulationGuardTests {
    /// Columns a scan of the Picard fixture is not expected to populate, each
    /// with the reason. Adding a column to one of the guarded tables without
    /// either a writer the scan exercises or a line here fails the build.
    private static let allowed: [String: String] = [
        "artists.disambiguation": "MusicBrainz enrichment job, network (#401)",
        "artists.musicbrainz_fetched_at": "MusicBrainz enrichment job, network (#401)",
        "tracks.key": "fixture has no musical-key tag (#407)",
        "tracks.acoustid_fingerprint": "identify flow, network",
        "tracks.acoustid_id": "identify flow, network",
        "tracks.provenance_suspected": "transcode analysis job (ADR-075)",
        "tracks.provenance_confidence": "transcode analysis job (ADR-075)",
        "tracks.provenance_shelf_hz": "transcode analysis job (ADR-075)",
        "tracks.provenance_analysed_at": "transcode analysis job (ADR-075)",
        "tracks.play_count": "user play state",
        "tracks.skip_count": "user play state",
        "tracks.last_played_at": "user play state",
        "tracks.play_duration_total": "user play state",
        "tracks.rating": "user state",
        "tracks.loved": "user state",
        "tracks.excluded_from_shuffle": "user state",
        "tracks.skip_after_seconds": "user state",
        "tracks.disabled": "set when a file goes missing",
        "tracks.user_edited": "set by the tag editor",
        "tracks.needs_conflict_review": "set by the conflict resolver",
        "tracks.content_hash": "sync hashing job (ADR-065)",
        "albums.force_gapless": "user state",
        "albums.excluded_from_shuffle": "user state",
    ]

    private static let tables = ["tracks", "albums", "artists", "cover_art"]

    @Test("every column of tracks, albums, artists and cover_art is populated by a scan or allow-listed with a reason")
    func everyColumnPopulatedOrExplained() async throws {
        let db = try await scannedLibrary()
        let allowed = Self.allowed
        let tables = Self.tables
        let (unexplained, staleAllowances): ([String], [String]) = try await db.read { grdb in
            var unexplained: [String] = []
            var stale: [String] = []
            for table in tables {
                let columns = try Row.fetchAll(grdb, sql: "PRAGMA table_info(\(table))")
                for column in columns {
                    let name: String = column["name"]
                    let dflt: String? = column["dflt_value"]
                    let key = "\(table).\(name)"
                    var sql = "SELECT COUNT(*) FROM \(table) WHERE \"\(name)\" IS NOT NULL"
                    if let dflt { sql += " AND \"\(name)\" IS NOT \(dflt)" }
                    let populated = try Int.fetchOne(grdb, sql: sql) ?? 0
                    if populated == 0, allowed[key] == nil { unexplained.append(key) }
                    if populated > 0, allowed[key] != nil { stale.append(key) }
                }
            }
            return (unexplained, stale)
        }
        #expect(unexplained.isEmpty, "never written by a scan and not allow-listed: \(unexplained)")
        #expect(staleAllowances.isEmpty, "allow-listed but the scan populates them; drop the allowance: \(staleAllowances)")
    }
}
