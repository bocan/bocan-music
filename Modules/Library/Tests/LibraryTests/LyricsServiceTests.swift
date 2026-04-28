import Foundation
import Metadata
import Persistence
import Testing
@testable import Library

// MARK: - LyricsService tests

@Suite("LyricsService")
struct LyricsServiceTests {
    // MARK: - Helpers

    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makeService(db: Database, fetcher: (any LRClibClientProtocol)? = nil) -> LyricsService {
        LyricsService(database: db, fetcher: fetcher)
    }

    // MARK: - Seed helpers

    private func seedTrack(db: Database, fileURL: String = "/tmp/test.flac", duration: Double = 180) async throws -> Int64 {
        let repo = TrackRepository(database: db)
        let now = Int64(Date().timeIntervalSince1970)
        return try await repo.upsert(Track(
            fileURL: fileURL,
            fileSize: 0,
            fileMtime: 0,
            fileFormat: "flac",
            duration: duration,
            addedAt: now,
            updatedAt: now
        ))
    }

    // MARK: - Basic CRUD

    @Test("lyrics returns nil when nothing is stored")
    func lyricsNilWhenEmpty() async throws {
        let db = try await makeDB()
        let svc = self.makeService(db: db)
        let id = try await seedTrack(db: db)
        let result = try await svc.lyrics(for: id)
        #expect(result == nil)
    }

    @Test("setLyrics saves unsynced doc and lyrics returns it")
    func savesAndReadsUnsynced() async throws {
        let db = try await makeDB()
        let svc = self.makeService(db: db)
        let id = try await seedTrack(db: db)

        let doc = LyricsDocument.unsynced("Hello\nWorld")
        try await svc.setLyrics(doc, for: id)

        let fetched = try await svc.lyrics(for: id)
        guard case let .unsynced(text) = fetched else {
            Issue.record("Expected .unsynced, got \(String(describing: fetched))")
            return
        }
        #expect(text.contains("Hello"))
    }

    @Test("setLyrics with nil deletes existing row")
    func deletesLyrics() async throws {
        let db = try await makeDB()
        let svc = self.makeService(db: db)
        let id = try await seedTrack(db: db)

        try await svc.setLyrics(.unsynced("Some text"), for: id)
        try await svc.setLyrics(nil, for: id)
        let result = try await svc.lyrics(for: id)
        #expect(result == nil)
    }

    @Test("setLyrics marks source = user by default")
    func sourceIsUser() async throws {
        let db = try await makeDB()
        let svc = self.makeService(db: db)
        let id = try await seedTrack(db: db)

        try await svc.setLyrics(.unsynced("text"), for: id)
        let repo = LyricsRepository(database: db)
        let row = try await repo.fetch(trackID: id)
        #expect(row?.source == "user")
    }

    // MARK: - Source priority

    @Test("user source wins over embedded source")
    func userWinsOverEmbedded() async throws {
        let db = try await makeDB()
        let svc = self.makeService(db: db)
        let id = try await seedTrack(db: db)

        // Plant embedded lyrics
        let repo = LyricsRepository(database: db)
        try await repo.save(Lyrics(trackID: id, lyricsText: "Embedded text", isSynced: false, source: "embedded"))

        // Plant user lyrics
        try await svc.setLyrics(.unsynced("User text"), for: id, source: "user")

        let result = try await svc.lyrics(for: id)
        guard case let .unsynced(text) = result else {
            Issue.record("Expected .unsynced")
            return
        }
        #expect(text == "User text")
    }

    @Test("lrclib source returned when no higher priority source exists")
    func lrclibFallback() async throws {
        let db = try await makeDB()
        let svc = self.makeService(db: db)
        let id = try await seedTrack(db: db)

        let repo = LyricsRepository(database: db)
        try await repo.save(Lyrics(trackID: id, lyricsText: "Fetched text", isSynced: false, source: "lrclib"))

        let result = try await svc.lyrics(for: id)
        guard case let .unsynced(text) = result else {
            Issue.record("Expected .unsynced, got \(String(describing: result))")
            return
        }
        #expect(text == "Fetched text")
    }

    // MARK: - Auto-fetch

    @Test("autoFetchIfMissing skips when fetcher is nil")
    func autoFetchSkipsWithoutFetcher() async throws {
        let db = try await makeDB()
        let svc = LyricsService(database: db, fetcher: nil)
        let id = try await seedTrack(db: db)

        let result = try await svc.autoFetchIfMissing(for: id)
        #expect(result == nil)
    }

    @Test("autoFetchIfMissing skips when lyrics already exist")
    func autoFetchSkipsWhenHasLyrics() async throws {
        let db = try await makeDB()
        let spy = SpyFetcher()
        let svc = self.makeService(db: db, fetcher: spy)
        let id = try await seedTrack(db: db)

        try await svc.setLyrics(.unsynced("existing"), for: id)
        _ = try await svc.autoFetchIfMissing(for: id)

        #expect(!spy.wasCalled)
    }

    @Test("autoFetchIfMissing calls fetcher when no lyrics exist")
    func autoFetchCallsFetcher() async throws {
        let db = try await makeDB()
        let spy = SpyFetcher(returnDoc: .unsynced("From lrclib"))
        let svc = self.makeService(db: db, fetcher: spy)
        let id = try await seedTrack(db: db)

        let result = try await svc.autoFetchIfMissing(for: id)
        #expect(spy.wasCalled)
        guard case let .unsynced(text) = result else {
            Issue.record("Expected .unsynced")
            return
        }
        #expect(text == "From lrclib")
    }

    // MARK: - Observe

    @Test("observe emits nil initially then updated document")
    func observeEmitsUpdates() async throws {
        let db = try await makeDB()
        let svc = self.makeService(db: db)
        let id = try await seedTrack(db: db)

        let stream = await svc.observe(id)
        var iterator = stream.makeAsyncIterator()

        // First emission — should be nil (no lyrics yet)
        let first = try await iterator.next()
        #expect(first == nil || first! == nil)

        // Save something
        try await svc.setLyrics(.unsynced("New lyrics"), for: id)

        // Next emission should contain the text
        let second = try await iterator.next()
        guard let doc = second as? LyricsDocument,
              case let .unsynced(text) = doc else {
            // The stream may yield nil-in-Optional<Optional> form; handle both
            if let optDoc = second, case let .unsynced(text) = optDoc {
                #expect(text.contains("New lyrics"))
                return
            }
            Issue.record("Expected non-nil lyrics document, got \(String(describing: second))")
            return
        }
        #expect(text.contains("New lyrics"))
    }
}

// MARK: - Spy fetcher

/// Test double that records calls and returns a fixed document.
final class SpyFetcher: LRClibClientProtocol, @unchecked Sendable {
    private(set) var wasCalled = false
    private let returnDoc: LyricsDocument?

    init(returnDoc: LyricsDocument? = nil) {
        self.returnDoc = returnDoc
    }

    func get(
        artist: String,
        title: String,
        album: String?,
        duration: TimeInterval
    ) async throws -> LyricsDocument? {
        self.wasCalled = true
        return self.returnDoc
    }

    func search(
        artist: String?,
        title: String?,
        album: String?
    ) async throws -> [LyricsDocument] {
        []
    }
}
