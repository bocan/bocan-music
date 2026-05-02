import Acoustics
import Foundation
import Persistence
import Testing
@testable import Library

// MARK: - FingerprintServiceTests

@Suite("FingerprintService")
struct FingerprintServiceTests {
    // MARK: - Helpers

    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    /// Inserts a bare track with no real file and returns its row ID + the `Track`.
    private func insertTrack(in db: Database) async throws -> (trackID: Int64, track: Track) {
        let now = Int64(Date().timeIntervalSince1970)
        let track = Track(fileURL: "file:///tmp/test.mp3", title: "Test Track", addedAt: now, updatedAt: now)
        let id = try await TrackRepository(database: db).insert(track)
        var saved = track
        saved.id = id
        return (id, saved)
    }

    private func makeAcoustID(json: String, statusCode: Int = 200) -> AcoustIDClient {
        let mock = MockHTTPClient(responseData: Data(json.utf8), statusCode: statusCode)
        return AcoustIDClient(
            apiKey: "test-key",
            rateLimiter: RateLimiter(maxRequests: 100, per: 1.0),
            httpClient: mock
        )
    }

    private func makeMB(json: String, statusCode: Int = 200) -> Acoustics.MusicBrainzClient {
        let mock = MockHTTPClient(responseData: Data(json.utf8), statusCode: statusCode)
        return MusicBrainzClient(
            userAgent: "TestAgent/1.0 ( test@example.com )",
            rateLimiter: RateLimiter(maxRequests: 100, per: 1.0),
            httpClient: mock
        )
    }

    private func makeService(
        fingerprinter: some Fingerprintable,
        acoustid: AcoustIDClient,
        mb: Acoustics.MusicBrainzClient,
        db: Database
    ) -> FingerprintService {
        FingerprintService(
            fingerprinter: fingerprinter,
            acoustidClient: acoustid,
            mbClient: mb,
            store: FingerprintStore(database: db)
        )
    }

    // MARK: - Happy path

    @Test("identify returns candidates enriched via MusicBrainz and sorted by score")
    func identifyHappyPath() async throws {
        let db = try await makeDB()
        let (_, track) = try await insertTrack(in: db)

        let acoustid = self.makeAcoustID(json: acoustidSingleJSON)
        let mb = self.makeMB(json: mbRecordingJSON)
        let service = self.makeService(
            fingerprinter: StubFingerprinter(fingerprint: "AQAAZ0mk", duration: 259),
            acoustid: acoustid,
            mb: mb,
            db: db
        )

        let candidates = try await service.identify(track: track)

        #expect(!candidates.isEmpty)
        // Candidates must be sorted highest score first
        if candidates.count > 1 {
            #expect(candidates[0].score >= candidates[1].score)
        }
        // MusicBrainz enrichment should populate title and artist
        let first = try #require(candidates.first)
        #expect(!first.title.isEmpty)
        #expect(!first.artist.isEmpty)
    }

    // MARK: - DB persistence

    @Test("fingerprint and acoustid_id are always written to DB even when no candidates returned")
    func fingerprintAlwaysPersisted() async throws {
        let db = try await makeDB()
        let (trackID, track) = try await insertTrack(in: db)

        // AcoustID returns results with no recordings — zero candidates, but DB must still be written
        let acoustid = self.makeAcoustID(json: acoustidEmptyRecordingsJSON)
        let mb = self.makeMB(json: mbRecordingJSON)
        let service = self.makeService(
            fingerprinter: StubFingerprinter(fingerprint: "TESTFP123", duration: 180),
            acoustid: acoustid,
            mb: mb,
            db: db
        )

        let candidates = try await service.identify(track: track)
        #expect(candidates.isEmpty)

        // Verify the fingerprint was written to the DB
        let savedTrack = try await TrackRepository(database: db).fetch(id: trackID)
        #expect(savedTrack.acoustidFingerprint == "TESTFP123")
        #expect(savedTrack.acoustidID == "2dd41a10-3b4c-4bcd-87dc-c49dda6b5660")
    }

    @Test("fingerprint written to DB on high-confidence match")
    func fingerprintWrittenOnMatch() async throws {
        let db = try await makeDB()
        let (trackID, track) = try await insertTrack(in: db)

        let acoustid = self.makeAcoustID(json: acoustidSingleJSON)
        let mb = self.makeMB(json: mbRecordingJSON)
        let service = self.makeService(
            fingerprinter: StubFingerprinter(fingerprint: "MYFP-HASH", duration: 259),
            acoustid: acoustid,
            mb: mb,
            db: db
        )

        _ = try await service.identify(track: track)

        let savedTrack = try await TrackRepository(database: db).fetch(id: trackID)
        #expect(savedTrack.acoustidFingerprint == "MYFP-HASH")
        #expect(savedTrack.acoustidID != nil)
    }

    // MARK: - Low-confidence fallback

    @Test("candidates below 0.5 confidence use AcoustID fallback without MusicBrainz enrichment")
    func lowConfidenceFallback() async throws {
        let db = try await makeDB()
        let (_, track) = try await insertTrack(in: db)

        // Score 0.3 — below the 0.5 MB enrichment threshold
        let acoustid = self.makeAcoustID(json: acoustidLowConfidenceJSON)
        // MB mock returns an error to confirm it is never called for low-confidence matches
        let mb = self.makeMB(json: "", statusCode: 500)
        let service = self.makeService(
            fingerprinter: StubFingerprinter(fingerprint: "LOWFP", duration: 120),
            acoustid: acoustid,
            mb: mb,
            db: db
        )

        let candidates = try await service.identify(track: track)

        // Should still get a candidate built from AcoustID-only data
        let first = try #require(candidates.first)
        #expect(first.score < 0.5)
        // AcoustID-only fallback still populates title from recording data
        #expect(!first.title.isEmpty)
    }

    // MARK: - AcoustID empty response

    @Test("identify returns empty array when AcoustID finds no results")
    func noResults() async throws {
        let db = try await makeDB()
        let (_, track) = try await insertTrack(in: db)

        let acoustid = self.makeAcoustID(json: acoustidNoResultsJSON)
        let mb = self.makeMB(json: mbRecordingJSON)
        let service = self.makeService(
            fingerprinter: StubFingerprinter(fingerprint: "NOFP", duration: 60),
            acoustid: acoustid,
            mb: mb,
            db: db
        )

        let candidates = try await service.identify(track: track)
        #expect(candidates.isEmpty)
    }

    // MARK: - Fingerprinter failure

    @Test("identify propagates fingerprinter failure")
    func fingerprintFailure() async throws {
        let db = try await makeDB()
        let (_, track) = try await insertTrack(in: db)

        let acoustid = self.makeAcoustID(json: acoustidSingleJSON)
        let mb = self.makeMB(json: mbRecordingJSON)
        let service = self.makeService(
            fingerprinter: FailingFingerprinter(),
            acoustid: acoustid,
            mb: mb,
            db: db
        )

        await #expect(throws: (any Error).self) {
            try await service.identify(track: track)
        }
    }

    // MARK: - Missing track ID

    @Test("identify throws missingID when track has no database ID")
    func missingTrackID() async throws {
        let db = try await makeDB()
        let now = Int64(Date().timeIntervalSince1970)
        // Track with no id (not yet persisted)
        let track = Track(fileURL: "file:///tmp/ghost.mp3", title: "Ghost", addedAt: now, updatedAt: now)

        let service = self.makeService(
            fingerprinter: StubFingerprinter(fingerprint: "FP", duration: 60),
            acoustid: self.makeAcoustID(json: acoustidSingleJSON),
            mb: self.makeMB(json: mbRecordingJSON),
            db: db
        )

        var caughtMissingID = false
        do {
            _ = try await service.identify(track: track)
        } catch LibraryError.missingID {
            caughtMissingID = true
        }
        #expect(caughtMissingID)
    }
}

// MARK: - Test doubles

/// Returns a fixed fingerprint string without invoking `fpcalc`.
private struct StubFingerprinter: Fingerprintable {
    let fingerprint: String
    let duration: Int

    func fingerprint(url: URL) async throws -> (fingerprint: String, duration: Int) {
        (self.fingerprint, self.duration)
    }
}

/// Always throws to simulate a `fpcalc` crash.
private struct FailingFingerprinter: Fingerprintable {
    func fingerprint(url: URL) async throws -> (fingerprint: String, duration: Int) {
        throw AcousticsError.fpcalcFailed(exitCode: 1, stderr: "stub failure")
    }
}

/// Minimal `HTTPClient` stub that returns pre-canned data.
private final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    let responseData: Data
    let statusCode: Int

    init(responseData: Data, statusCode: Int = 200) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (self.responseData, response)
    }
}

// MARK: - Inline JSON fixtures

/// Single high-confidence AcoustID result with one recording.
private let acoustidSingleJSON = """
{
  "status": "ok",
  "results": [
    {
      "id": "2dd41a10-3b4c-4bcd-87dc-c49dda6b5660",
      "score": 0.947,
      "recordings": [
        {
          "id": "f76e9be1-bd30-4b26-b0a6-1b8e9c70e4df",
          "title": "Come Together",
          "duration": 259,
          "artists": [{ "id": "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d", "name": "The Beatles" }],
          "releases": [{ "id": "abc", "title": "Abbey Road", "date": { "year": 1969 } }]
        }
      ]
    }
  ]
}
"""

/// AcoustID result with a result row but no recordings list — zero candidates.
private let acoustidEmptyRecordingsJSON = """
{
  "status": "ok",
  "results": [
    {
      "id": "2dd41a10-3b4c-4bcd-87dc-c49dda6b5660",
      "score": 0.90,
      "recordings": []
    }
  ]
}
"""

/// AcoustID result with score below 0.5 — should use fallback path.
private let acoustidLowConfidenceJSON = """
{
  "status": "ok",
  "results": [
    {
      "id": "aaaaaaaa-0000-0000-0000-000000000001",
      "score": 0.30,
      "recordings": [
        {
          "id": "bbbbbbbb-0000-0000-0000-000000000002",
          "title": "Unknown Song",
          "duration": 120,
          "artists": [{ "id": "cccccccc-0000-0000-0000-000000000003", "name": "Unknown Artist" }],
          "releases": []
        }
      ]
    }
  ]
}
"""

/// AcoustID response with an empty results array.
private let acoustidNoResultsJSON = """
{
  "status": "ok",
  "results": []
}
"""

/// Minimal MusicBrainz recording response for "Come Together".
private let mbRecordingJSON = """
{
  "id": "f76e9be1-bd30-4b26-b0a6-1b8e9c70e4df",
  "title": "Come Together",
  "length": 259173,
  "artist-credit": [
    {
      "name": "The Beatles",
      "joinphrase": "",
      "artist": { "id": "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d", "name": "The Beatles" }
    }
  ],
  "releases": [
    {
      "id": "b3b7e848-dba3-3a72-a9b5-a116b3f1e77c",
      "title": "Abbey Road",
      "date": "1969-09-26",
      "status": "Official",
      "artist-credit": [
        {
          "name": "The Beatles",
          "joinphrase": "",
          "artist": { "id": "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d", "name": "The Beatles" }
        }
      ],
      "label-info": [
        {
          "label": { "id": "46f0f4cd-8aab-4b33-b698-f459faf64190", "name": "Apple Records" },
          "catalog-number": "PCS 7088"
        }
      ],
      "media": [
        {
          "position": 1,
          "track-count": 17,
          "tracks": [{ "number": "9", "title": "Come Together", "length": 259173 }]
        }
      ]
    }
  ],
  "tags": [{ "name": "rock", "count": 10 }]
}
"""
