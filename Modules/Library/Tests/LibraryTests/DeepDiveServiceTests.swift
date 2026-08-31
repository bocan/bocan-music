import Acoustics
import Foundation
import Persistence
import Testing
@testable import Library

/// Routes MusicBrainz and Wikimedia URLs to canned JSON; anything unrouted is
/// a 404, and `offline` makes every request throw.
private final class RoutingHTTP: HTTPClient, @unchecked Sendable {
    var routes: [(match: String, body: String)] = []
    var offline = false
    private(set) var requests: [String] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!.absoluteString.removingPercentEncoding ?? ""
        self.requests.append(url)
        if self.offline { throw URLError(.notConnectedToInternet) }
        let hit = self.routes.first { url.contains($0.match) }
        let status = hit == nil ? 404 : 200
        return (Data((hit?.body ?? "").utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let beatlesMBID = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"

private let artistJSON = """
{"id":"\(beatlesMBID)","name":"The Beatles","sort-name":"Beatles, The","disambiguation":"","type":"Group","country":"GB",
 "life-span":{"begin":"1957-03","end":"1970-04-10","ended":true},
 "relations":[
  {"type":"wikidata","direction":"forward","url":{"resource":"https://www.wikidata.org/wiki/Q1299"}},
  {"type":"discogs","direction":"forward","url":{"resource":"https://www.discogs.com/artist/82730"}},
  {"type":"member of band","direction":"backward","begin":"1957-03","end":"1970-04-10","ended":true,"attributes":["guitar","lead vocals"],"artist":{"id":"4d5447d7","name":"John Lennon"}},
  {"type":"member of band","direction":"backward","begin":"1960-08","end":"1962-08","ended":true,"attributes":["drums"],"artist":{"id":"f3bd7f47","name":"Pete Best"}}]}
"""
private let browseJSON = """
{"release-group-count":3,"release-group-offset":0,"release-groups":[
 {"id":"rg-please","title":"Please Please Me","primary-type":"Album","first-release-date":"1963-03-22"},
 {"id":"rg-love","title":"Love Me Do","primary-type":"Single","first-release-date":"1962-10-05"},
 {"id":"rg-abbey","title":"Abbey Road","primary-type":"Album","first-release-date":"1969-09-26"}]}
"""
private let wikidataJSON = #"{"entities":{"Q1299":{"id":"Q1299","sitelinks":{"enwiki":{"site":"enwiki","title":"The Beatles"}}}}}"#
private let summaryJSON = #"{"title":"The Beatles","extract":"The Beatles were an English rock band formed in Liverpool in 1960.","content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/The_Beatles"}}}"#
private let searchJSON = #"{"artists":[{"id":"b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d","name":"The Beatles","score":100,"type":"Group"}]}"#
private let releaseJSON = """
{"id":"rel-a","title":"Abbey Road","date":"1969-09-26","country":"GB","status":"Official","barcode":"077774644624",
 "artist-credit":[{"name":"The Beatles","artist":{"id":"\(beatlesMBID)","name":"The Beatles"}}],
 "label-info":[{"catalog-number":"PCS 7088","label":{"id":"l1","name":"Apple Records"}}],
 "media":[{"position":1,"format":"12\\" Vinyl","track-count":17}],
 "release-group":{"id":"rg-abbey","title":"Abbey Road","primary-type":"Album","first-release-date":"1969-09-26"}}
"""
private let groupLookupJSON = """
{"id":"rg-abbey","title":"Abbey Road","primary-type":"Album","first-release-date":"1969-09-26",
 "releases":[{"id":"rel-2019","title":"Abbey Road (Anniversary)","date":"2019-09-27","status":"Official"},
             {"id":"rel-a","title":"Abbey Road","date":"1969-09-26","status":"Official"},
             {"id":"rel-boot","title":"Abbey Road","date":"1969","status":"Bootleg"}]}
"""
private let workJSON = #"{"id":"w-1","title":"Come Together","relations":[{"type":"composer","artist":{"id":"a-l","name":"John Lennon"}},{"type":"composer","artist":{"id":"a-m","name":"Paul McCartney"}},{"type":"lyricist","artist":{"id":"a-l","name":"John Lennon"}}]}"#
private let recordingJSON = """
{"id":"rec-1","title":"Come Together","length":259000,"isrcs":["GBAYE0601690"],
 "relations":[{"type":"performance","direction":"forward","work":{"id":"w-1","title":"Come Together"}}],
 "artist-credit":[{"name":"The Beatles","artist":{"id":"\(beatlesMBID)","name":"The Beatles"}}],
 "tags":[{"name":"rock","count":9},{"name":"pop","count":3}],
 "releases":[{"id":"rel-a","title":"Abbey Road","date":"1969-09-26","country":"GB","status":"Official","release-group":{"id":"rg-abbey","primary-type":"Album"}},
             {"id":"rel-b","title":"1967-1970","date":"1973","country":"US","status":"Official","release-group":{"id":"rg-red","primary-type":"Album","secondary-types":["Compilation"]}}]}
"""

private let groupSearchJSON = """
{"count":1,"release-groups":[{"id":"rg-abbey","score":100,"title":"Abbey Road","primary-type":"Album","first-release-date":"1969-09-26"}]}
"""
private let recordingSearchJSON = """
{"count":1,"recordings":[{"id":"rec-1","score":100,"title":"Come Together","artist-credit":[{"name":"The Beatles"}]}]}
"""

/// Records what a confirm would have written to file tags.
private final class SaverSpy: DeepDiveTagSaving, @unchecked Sendable {
    private(set) var recordings: [(mbid: String, trackID: Int64)] = []
    private(set) var groups: [(mbid: String, trackIDs: [Int64])] = []
    func saveRecordingID(_ mbid: String, trackID: Int64) async throws {
        self.recordings.append((mbid, trackID))
    }

    func saveReleaseGroupID(_ mbid: String, trackIDs: [Int64]) async throws {
        self.groups.append((mbid, trackIDs))
    }
}

private struct Bed {
    let db: Database
    let http: RoutingHTTP
    let service: DeepDiveService
    let cacheRoot: URL
}

private func makeBed(ttl: TimeInterval = 3600) async throws -> Bed {
    let db = try await Database(location: .inMemory)
    let http = RoutingHTTP()
    http.routes = [
        ("/ws/2/artist/\(beatlesMBID)?", artistJSON),
        ("/ws/2/artist?", searchJSON),
        ("/ws/2/release-group?artist=", browseJSON),
        // The client sorts query keys ("limit" before "query"), so match on
        // the query content, which is unique per search kind.
        ("AND releasegroup:\"", groupSearchJSON),
        ("AND recording:\"", recordingSearchJSON),
        ("/ws/2/recording/rec-1", recordingJSON),
        ("/ws/2/release/rel-a?", releaseJSON),
        ("/ws/2/release-group/rg-abbey?", groupLookupJSON),
        ("/ws/2/work/w-1?", workJSON),
        ("Special:EntityData/Q1299.json", wikidataJSON),
        ("page/summary/The_Beatles", summaryJSON),
    ]
    let limiter = RateLimiter(maxRequests: 1000, per: 1.0)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("deepdive-\(UUID().uuidString)", isDirectory: true)
    let service = DeepDiveService(
        database: db,
        musicBrainz: MusicBrainzClient(userAgent: "Bocan/test ( https://bocan.app )", rateLimiter: limiter, httpClient: http),
        wikipedia: WikipediaClient(userAgent: "Bocan/test ( https://bocan.app )", rateLimiter: limiter, httpClient: http),
        cache: DeepDiveCache(root: root, ttl: ttl),
        now: { Date(timeIntervalSince1970: 1_720_000_000) }
    )
    return Bed(db: db, http: http, service: service, cacheRoot: root)
}

@Suite("DeepDiveService (#413)")
struct DeepDiveServiceTests {
    @Test("artist report assembles bio, members, links and discography with owned albums marked")
    func artistReport() async throws {
        let bed = try await makeBed()
        let artist = try await ArtistRepository(database: bed.db).findOrCreate(name: "The Beatles", musicbrainzID: beatlesMBID)
        let albums = AlbumRepository(database: bed.db)
        let abbey = try await albums.findOrCreate(title: "Abbey Road", albumArtistID: artist.id)
        try await albums.recomputeMusicBrainzIDs(albumID: #require(abbey.id)) // stays NULL: no tracks
        _ = try await albums.findOrCreate(title: "Love Me Do", albumArtistID: artist.id)

        let report = try await bed.service.artistReport(artistID: #require(artist.id))
        #expect(report.name == "The Beatles")
        #expect(report.mbidGuessed == false)
        #expect(report.country == "GB")
        #expect(report.activeFrom == "1957-03")
        #expect(report.ended)
        #expect(report.bio?.extract.hasPrefix("The Beatles were an English rock band") == true)
        #expect(report.bio?.attribution == "Wikipedia, CC BY-SA 4.0")
        #expect(report.members.map(\.name) == ["John Lennon", "Pete Best"])
        #expect(report.members.first?.roles == ["guitar", "lead vocals"])
        #expect(report.links.map(\.type) == ["discogs", "wikidata"])
        #expect(report.discography.map(\.title) == ["Love Me Do", "Please Please Me", "Abbey Road"], "by year")
        #expect(report.discography.map(\.owned) == [true, false, true], "matched by title under this artist")
        #expect(report.discography.first?.primaryType == "Single")

        // The same lookup stamps the enrichment columns.
        #expect(try await ArtistRepository(database: bed.db).fetch(id: #require(artist.id)).musicbrainzFetchedAt == 1_720_000_000)

        // Second call is served from the cache: no new requests.
        let before = bed.http.requests.count
        _ = try await bed.service.artistReport(artistID: #require(artist.id))
        #expect(bed.http.requests.count == before)
    }

    @Test("an artist without an MBID is guessed from a confident name search and flagged")
    func guessedMBID() async throws {
        let bed = try await makeBed()
        let artist = try await ArtistRepository(database: bed.db).findOrCreate(name: "The Beatles")
        let report = try await bed.service.artistReport(artistID: #require(artist.id))
        #expect(report.mbidGuessed)
        #expect(report.mbid == beatlesMBID)
        #expect(bed.http.requests.first?.contains("/ws/2/artist?") == true)
        #expect(
            try await ArtistRepository(database: bed.db).fetch(id: #require(artist.id)).musicbrainzArtistID == nil,
            "a guess is not persisted"
        )
    }

    @Test("confirming a guess persists the id as a search match and unflags the cached report")
    func confirmGuess() async throws {
        let bed = try await makeBed()
        let repo = ArtistRepository(database: bed.db)
        let artist = try await repo.findOrCreate(name: "The Beatles")
        let id = try #require(artist.id)
        let guessed = try await bed.service.artistReport(artistID: id)
        #expect(guessed.mbidGuessed)

        let confirmed = try await bed.service.confirmArtistMBID(report: guessed)
        #expect(!confirmed.mbidGuessed)
        let row = try await repo.fetch(id: id)
        #expect(row.musicbrainzArtistID == beatlesMBID)
        #expect(row.musicbrainzIDSource == "search")
        #expect(row.sortName == "Beatles, The")
        #expect(row.musicbrainzFetchedAt == 1_720_000_000)

        // The next report comes from the stored id and the cache, unflagged, without a search.
        let requestsBefore = bed.http.requests.count
        let again = try await bed.service.artistReport(artistID: id)
        #expect(!again.mbidGuessed)
        #expect(bed.http.requests.count == requestsBefore)
    }

    @Test("a stale cached report is served when offline, and offline with no cache throws")
    func staleIfOffline() async throws {
        let bed = try await makeBed(ttl: 0)
        let artist = try await ArtistRepository(database: bed.db).findOrCreate(name: "The Beatles", musicbrainzID: beatlesMBID)
        let first = try await bed.service.artistReport(artistID: #require(artist.id))
        bed.http.offline = true
        let stale = try await bed.service.artistReport(artistID: #require(artist.id))
        #expect(stale == first)

        let other = try await ArtistRepository(database: bed.db).findOrCreate(name: "Nobody", musicbrainzID: "mb-nobody")
        await #expect(throws: DeepDiveError.offline) {
            _ = try await bed.service.artistReport(artistID: #require(other.id))
        }
    }

    @Test("track report needs a recording MBID and lists appearances by year")
    func trackReport() async throws {
        let bed = try await makeBed()
        let tracks = TrackRepository(database: bed.db)
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            fileURL: "file:///tmp/ct.flac",
            fileSize: 1,
            fileMtime: now,
            fileFormat: "flac",
            duration: 259,
            title: "Come Together",
            addedAt: now,
            updatedAt: now
        )
        let bare = try await tracks.upsert(track)
        await #expect(throws: DeepDiveError.noIdentifier) {
            _ = try await bed.service.trackReport(trackID: bare)
        }
        track.fileURL = "file:///tmp/ct2.flac"
        track.musicbrainzRecordingID = "rec-1"
        let id = try await tracks.upsert(track)
        let report = try await bed.service.trackReport(trackID: id)
        #expect(report.title == "Come Together")
        #expect(report.artistCredit == "The Beatles")
        #expect(report.length == 259_000)
        #expect(report.isrcs == ["GBAYE0601690"])
        #expect(report.firstReleaseYear == 1969)
        #expect(report.tags == ["rock", "pop"])
        #expect(report.appearances.map(\.releaseTitle) == ["Abbey Road", "1967-1970"])
        #expect(report.appearances.last?.secondaryTypes == ["Compilation"])
        #expect(report.works.map(\.title) == ["Come Together"])
        #expect(report.works.first?.composers == ["John Lennon", "Paul McCartney"])
        #expect(report.works.first?.lyricists == ["John Lennon"])
        #expect(report.acoustIDURL == nil)
    }

    @Test("album report reads the release, counts owned tracks, and lists the artist's nearby releases")
    func albumReport() async throws {
        let bed = try await makeBed()
        let artist = try await ArtistRepository(database: bed.db).findOrCreate(name: "The Beatles", musicbrainzID: beatlesMBID)
        let albums = AlbumRepository(database: bed.db)
        let abbey = try await albums.findOrCreate(title: "Abbey Road", albumArtistID: artist.id)
        _ = try await albums.findOrCreate(title: "Please Please Me", albumArtistID: artist.id)
        let tracks = TrackRepository(database: bed.db)
        let now = Int64(Date().timeIntervalSince1970)
        for n in 1 ... 3 {
            var track = Track(
                fileURL: "file:///tmp/ar-\(n).flac",
                fileSize: 1,
                fileMtime: now,
                fileFormat: "flac",
                duration: 1,
                title: "T\(n)",
                addedAt: now,
                updatedAt: now
            )
            track.albumID = abbey.id
            track.musicbrainzReleaseID = "rel-a"
            _ = try await tracks.upsert(track)
        }
        try await albums.recomputeMusicBrainzIDs(albumID: #require(abbey.id))

        let report = try await bed.service.albumReport(albumID: #require(abbey.id))
        #expect(report.title == "Abbey Road")
        #expect(report.releaseMBID == "rel-a")
        #expect(report.releaseChosen == false)
        #expect(report.mbidGuessed == false)
        #expect(report.labels == [AlbumReport.Label(name: "Apple Records", catalogNumber: "PCS 7088")])
        #expect(report.formats == ["12\" Vinyl"])
        #expect(report.trackCount == 17)
        #expect(report.ownedTrackCount == 3)
        #expect(report.country == "GB")
        #expect(report.barcode == "077774644624")
        #expect(report.coverArtArchiveURL.absoluteString == "https://coverartarchive.org/release/rel-a")
        // Browse fixture: Please Please Me 1963, Love Me Do 1962, Abbey Road 1969 (self, excluded). Within two years of 1969: none of
        // those.
        #expect(report.nearby.isEmpty)
    }

    @Test("an album with only a release-group id gets the earliest official release chosen")
    func albumReportFromGroup() async throws {
        let bed = try await makeBed()
        let albums = AlbumRepository(database: bed.db)
        let album = try await albums.findOrCreate(title: "Abbey Road", albumArtistID: nil)
        try await bed.db.write { db in
            try db.execute(sql: "UPDATE albums SET musicbrainz_release_group_id = 'rg-abbey' WHERE id = ?", arguments: [album.id!])
        }
        let report = try await bed.service.albumReport(albumID: #require(album.id))
        #expect(report.releaseChosen)
        #expect(report.releaseMBID == "rel-a", "earliest official, not the 2019 reissue or the bootleg")
        #expect(bed.http.requests.contains { $0.contains("/ws/2/release-group/rg-abbey?") })
    }

    @Test("an album with no MusicBrainz ids at all is found by a confident name search and flagged guessed")
    func albumReportGuessed() async throws {
        let bed = try await makeBed()
        let artist = try await ArtistRepository(database: bed.db).findOrCreate(name: "The Beatles", musicbrainzID: beatlesMBID)
        let album = try await AlbumRepository(database: bed.db).findOrCreate(title: " Abbey Road ", albumArtistID: artist.id)

        let report = try await bed.service.albumReport(albumID: #require(album.id))
        #expect(report.mbidGuessed)
        #expect(report.releaseChosen, "the guessed group still resolves to its earliest official release")
        #expect(report.releaseMBID == "rel-a")
        #expect(
            bed.http.requests.contains { $0.contains("query=artist:\"The Beatles\" AND releasegroup:\"Abbey Road\"") },
            "the search uses trimmed names"
        )
    }

    @Test("a track with no recording id is found by a confident artist + title search and flagged guessed")
    func trackReportGuessed() async throws {
        let bed = try await makeBed()
        let artist = try await ArtistRepository(database: bed.db).findOrCreate(name: "The Beatles", musicbrainzID: beatlesMBID)
        let tracks = TrackRepository(database: bed.db)
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            fileURL: "file:///tmp/ct3.flac",
            fileSize: 1,
            fileMtime: now,
            fileFormat: "flac",
            duration: 259,
            title: " Come Together ",
            addedAt: now,
            updatedAt: now
        )
        track.artistID = artist.id
        let id = try await tracks.upsert(track)

        let report = try await bed.service.trackReport(trackID: id)
        #expect(report.mbidGuessed)
        #expect(report.recordingMBID == "rec-1")
        #expect(report.title == "Come Together")
        #expect(
            bed.http.requests.contains { $0.contains("query=artist:\"The Beatles\" AND recording:\"Come Together\"") },
            "the search uses trimmed names"
        )
    }

    @Test("saving a guessed track match writes the recording id to the file and unflags the cached report")
    func trackSaveToTags() async throws {
        let bed = try await makeBed()
        let artist = try await ArtistRepository(database: bed.db).findOrCreate(name: "The Beatles", musicbrainzID: beatlesMBID)
        let tracks = TrackRepository(database: bed.db)
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            fileURL: "file:///tmp/ct4.flac",
            fileSize: 1,
            fileMtime: now,
            fileFormat: "flac",
            duration: 259,
            title: "Come Together",
            addedAt: now,
            updatedAt: now
        )
        track.artistID = artist.id
        let id = try await tracks.upsert(track)
        let guessed = try await bed.service.trackReport(trackID: id)
        #expect(guessed.mbidGuessed)

        let spy = SaverSpy()
        let confirmed = try await bed.service.confirmTrackMatch(report: guessed, saver: spy)
        #expect(!confirmed.mbidGuessed)
        #expect(spy.recordings.map(\.mbid) == ["rec-1"])
        #expect(spy.recordings.map(\.trackID) == [id])

        // The re-cached report is served unflagged.
        let again = try await bed.service.trackReport(trackID: id)
        #expect(!again.mbidGuessed)
    }

    @Test("saving a guessed album match writes the release-group id to every track in one call")
    func albumSaveToTags() async throws {
        let bed = try await makeBed()
        let artist = try await ArtistRepository(database: bed.db).findOrCreate(name: "The Beatles", musicbrainzID: beatlesMBID)
        let albums = AlbumRepository(database: bed.db)
        let album = try await albums.findOrCreate(title: "Abbey Road", albumArtistID: artist.id)
        let tracks = TrackRepository(database: bed.db)
        let now = Int64(Date().timeIntervalSince1970)
        var ids: [Int64] = []
        for n in 1 ... 2 {
            var track = Track(
                fileURL: "file:///tmp/st-\(n).flac",
                fileSize: 1,
                fileMtime: now,
                fileFormat: "flac",
                duration: 1,
                title: "T\(n)",
                addedAt: now,
                updatedAt: now
            )
            track.albumID = album.id
            try await ids.append(tracks.upsert(track))
        }
        let guessed = try await bed.service.albumReport(albumID: #require(album.id))
        #expect(guessed.mbidGuessed)

        let spy = SaverSpy()
        let outcome = try await bed.service.confirmAlbumMatch(report: guessed, saver: spy)
        #expect(!outcome.report.mbidGuessed)
        #expect(outcome.tracksWritten == 2)
        #expect(spy.groups.map(\.mbid) == ["rg-abbey"])
        #expect(spy.groups.first?.trackIDs.sorted() == ids.sorted())

        // The re-cached report is served unflagged.
        let again = try await bed.service.albumReport(albumID: #require(album.id))
        #expect(!again.mbidGuessed)
    }

    @Test("a name match below the confidence threshold is not used")
    func lowScoreRejected() async throws {
        let bed = try await makeBed()
        bed.http.routes = bed.http.routes.map { route in
            route.match == "AND releasegroup:\""
                ? (route.match, #"{"count":1,"release-groups":[{"id":"rg-wrong","score":62,"title":"Abbey Roadhouse"}]}"#)
                : route
        }
        let artist = try await ArtistRepository(database: bed.db).findOrCreate(name: "The Beatles")
        let album = try await AlbumRepository(database: bed.db).findOrCreate(title: "Abbey Road", albumArtistID: artist.id)
        await #expect(throws: DeepDiveError.noIdentifier) {
            _ = try await bed.service.albumReport(albumID: #require(album.id))
        }
    }
}
