import Foundation
import Testing
@testable import Library
@testable import Persistence

// MARK: - Stream-entry import tests (ADR-078 slice 4, issue #376)

/// A playlist of internet radio streams must import as radio stations, not as
/// an empty playlist of 26 misses.
@Suite("PlaylistImportService stream entries")
struct StreamImportTests {
    /// The real-world shape this feature was built against: a curated dial
    /// with `-1` durations, located titles, an HLS entry, a Shoutcast `/;`
    /// suffix, and extension-less mounts.
    private static let dialM3U = """
    #EXTM3U
    #PLAYLIST:The Liminal Dial

    #EXTINF:-1,SomaFM: Groove Salad (San Francisco, California)
    https://ice1.somafm.com/groovesalad-256-mp3

    #EXTINF:-1,Ambient Sleeping Pill (South Plainfield, New Jersey)
    https://radio.stereoscenic.com/asp-h

    #EXTINF:-1,Nightride FM - Synthwave (Global)
    https://stream.nightride.fm/nightride.mp3

    #EXTINF:-1,KUTX 98.9 FM (Austin, Texas)
    https://streams.kut.org/4428_192.mp3

    #EXTINF:-1,WWOZ 90.7 FM (New Orleans, Louisiana)
    https://wwoz-sc.streamguys1.com/wwoz-hi.mp3

    #EXTINF:-1,The Lot Radio (New York City)
    https://livepeercdn.studio/hls/85c28sa2o8wppm58/index.m3u8

    #EXTINF:-1,Radio Free Nashville (Nashville, Tennessee)
    https://ice23.securenetsystems.net/WRFNLP

    #EXTINF:-1,Kennet Radio (Newbury, United Kingdom)
    https://stream.kennetradio.com/128.mp3

    #EXTINF:-1,Kiosk Radio (Brussels, Belgium)
    https://kioskradiobxl.out.airtime.pro/kioskradiobxl_b

    #EXTINF:-1,Radio Caroline (United Kingdom)
    https://stream.radiocaroline.net/rc128/;stream.mp3

    #EXTINF:-1,KBOO FM (Portland, Oregon)
    https://live.kboo.fm:8443/high

    #EXTINF:-1,CKUT 90.3 FM (Montreal, Canada)
    https://delray.ckut.ca:8001/903fm-192-stereo
    """

    private struct Fixture {
        let db: Persistence.Database
        let importer: PlaylistImportService
        let playlists: PlaylistService
        let stations: RadioStationRepository
        let tracks: TrackRepository
    }

    private static func makeFixture() async throws -> Fixture {
        let db = try await Persistence.Database(location: .inMemory)
        let tracks = TrackRepository(database: db)
        let playlists = PlaylistService(database: db)
        let stations = RadioStationRepository(database: db)
        let importer = PlaylistImportService(
            resolver: TrackResolver(trackRepo: tracks),
            playlists: playlists,
            trackRepo: tracks,
            radioStations: stations
        )
        return Fixture(db: db, importer: importer, playlists: playlists, stations: stations, tracks: tracks)
    }

    private static func writeTempM3U(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-import-\(UUID().uuidString).m3u")
        try Data(body.utf8).write(to: url)
        return url
    }

    private static func playlistCount(_ db: Persistence.Database) async throws -> Int {
        try await db.read { grdb in
            try Int.fetchOne(grdb, sql: "SELECT COUNT(*) FROM playlists") ?? -1
        }
    }

    // MARK: - The #376 scenario

    @Test("an all-stream M3U imports as stations with no empty playlist")
    func allStreamFileYieldsStationsOnly() async throws {
        let fixture = try await Self.makeFixture()
        let url = try Self.writeTempM3U(Self.dialM3U)
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try await fixture.importer.importFile(at: url)

        #expect(report.playlistID == nil, "a pure station list must not create an empty playlist")
        #expect(report.stationsAdded == 12)
        #expect(report.streamEntryCount == 12)
        #expect(report.resolution.matches.isEmpty)
        #expect(report.resolution.misses.isEmpty, "stream entries must never be counted as misses")
        #expect(try await Self.playlistCount(fixture.db) == 0)

        let stations = try await fixture.stations.fetchAll()
        #expect(stations.count == 12)
        #expect(stations.contains { $0.name == "SomaFM: Groove Salad (San Francisco, California)" })
        #expect(stations.contains { $0.streamURL == "https://stream.radiocaroline.net/rc128/;stream.mp3" })
        #expect(stations.contains { $0.streamURL == "https://livepeercdn.studio/hls/85c28sa2o8wppm58/index.m3u8" })
    }

    @Test("re-importing the same dial is idempotent")
    func reimportIsIdempotent() async throws {
        let fixture = try await Self.makeFixture()
        let url = try Self.writeTempM3U(Self.dialM3U)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try await fixture.importer.importFile(at: url)
        let second = try await fixture.importer.importFile(at: url)

        #expect(first.stationsAdded == 12)
        #expect(second.stationsAdded == 0)
        #expect(second.streamEntryCount == 12)
        #expect(try await fixture.stations.fetchAll().count == 12)
        #expect(try await Self.playlistCount(fixture.db) == 0)
    }

    // MARK: - Mixed payloads

    @Test("a mixed playlist creates the playlist and the stations")
    func mixedPlaylistCreatesBoth() async throws {
        let fixture = try await Self.makeFixture()
        let now = Int64(Date().timeIntervalSince1970)
        let track = Track(
            fileURL: URL(fileURLWithPath: "/m/a.mp3").absoluteString,
            fileSize: 1,
            fileMtime: now,
            fileFormat: "mp3",
            duration: 180,
            title: "Song A",
            addedAt: now,
            updatedAt: now
        )
        let trackID = try await fixture.tracks.insert(track)

        let payload = PlaylistPayload(name: "Mixed", entries: [
            .init(path: "/m/a.mp3", absoluteURL: URL(fileURLWithPath: "/m/a.mp3")),
            .init(path: "https://ice1.somafm.com/groovesalad-256-mp3", absoluteURL: nil, titleHint: "Groove Salad"),
            .init(path: "/m/missing.mp3", absoluteURL: nil),
        ])
        let report = try await fixture.importer.importPayload(payload)

        let playlistID = try #require(report.playlistID)
        #expect(report.resolution.matches.count == 1)
        #expect(report.resolution.misses.count == 1, "only the local miss counts; the stream is not a miss")
        #expect(report.stationsAdded == 1)
        let members = try await fixture.playlists.tracks(in: playlistID)
        #expect(members.compactMap(\.id) == [trackID])
        #expect(try await fixture.stations.fetchAll().first?.name == "Groove Salad")
    }

    @Test("a playlist whose local entries all miss still creates the playlist")
    func allMissLocalEntriesStillCreatePlaylist() async throws {
        let fixture = try await Self.makeFixture()
        let payload = PlaylistPayload(name: "Misses", entries: [
            .init(path: "/gone/a.mp3", absoluteURL: nil),
            .init(path: "https://live.kboo.fm:8443/high", absoluteURL: nil),
        ])

        let report = try await fixture.importer.importPayload(payload)

        #expect(report.playlistID != nil, "one non-stream entry is enough to keep today's behaviour")
        #expect(report.resolution.misses.count == 1)
        #expect(report.stationsAdded == 1)
    }

    // MARK: - Naming and existing stations

    @Test("a stream entry without a title hint is named after its host")
    func namelessStreamNamedAfterHost() async throws {
        let fixture = try await Self.makeFixture()
        let payload = PlaylistPayload(name: "Bare", entries: [
            .init(path: "https://radio.stereoscenic.com/asp-h", absoluteURL: nil),
        ])

        _ = try await fixture.importer.importPayload(payload)

        #expect(try await fixture.stations.fetchAll().first?.name == "radio.stereoscenic.com")
    }

    @Test("import never renames a station the user already has")
    func importKeepsUserEdits() async throws {
        let fixture = try await Self.makeFixture()
        try await fixture.stations.insert(RadioStation(
            name: "My Groove Salad",
            streamURL: "https://ice1.somafm.com/groovesalad-256-mp3",
            addedAt: 0
        ))
        let payload = PlaylistPayload(name: "Dial", entries: [
            .init(path: "https://ice1.somafm.com/groovesalad-256-mp3", absoluteURL: nil, titleHint: "Groove Salad"),
        ])

        let report = try await fixture.importer.importPayload(payload)

        #expect(report.stationsAdded == 0)
        #expect(report.streamEntryCount == 1)
        let stations = try await fixture.stations.fetchAll()
        #expect(stations.count == 1)
        #expect(stations.first?.name == "My Groove Salad")
    }

    // MARK: - Other formats

    @Test("PLS stream entries import as stations")
    func plsStreamsImport() async throws {
        let fixture = try await Self.makeFixture()
        let pls = """
        [playlist]
        NumberOfEntries=2
        File1=https://ice1.somafm.com/groovesalad-256-mp3
        Title1=Groove Salad
        File2=https://live.kboo.fm:8443/high
        Title2=KBOO FM
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-import-\(UUID().uuidString).pls")
        try Data(pls.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try await fixture.importer.importFile(at: url)

        #expect(report.playlistID == nil)
        #expect(report.stationsAdded == 2)
        #expect(try await fixture.stations.fetchAll().map(\.name) == ["Groove Salad", "KBOO FM"])
    }

    @Test("XSPF stream locations import as stations")
    func xspfStreamsImport() async throws {
        let fixture = try await Self.makeFixture()
        let xspf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <playlist version="1" xmlns="http://xspf.org/ns/0/">
          <trackList>
            <track>
              <location>https://ice1.somafm.com/groovesalad-256-mp3</location>
              <title>Groove Salad</title>
            </track>
          </trackList>
        </playlist>
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-import-\(UUID().uuidString).xspf")
        try Data(xspf.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try await fixture.importer.importFile(at: url)

        #expect(report.playlistID == nil)
        #expect(report.stationsAdded == 1)
        #expect(try await fixture.stations.fetchAll().first?.name == "Groove Salad")
    }

    // MARK: - Preview

    @Test("previewFile reports the stations count without writing")
    func previewCountsStations() async throws {
        let fixture = try await Self.makeFixture()
        let url = try Self.writeTempM3U(Self.dialM3U)
        defer { try? FileManager.default.removeItem(at: url) }

        let counts = await fixture.importer.previewFile(at: url)

        #expect(counts.matched == 0)
        #expect(counts.missed == 0)
        #expect(counts.stations == 12)
        #expect(try await fixture.stations.fetchAll().isEmpty, "preview must not persist anything")
    }
}
