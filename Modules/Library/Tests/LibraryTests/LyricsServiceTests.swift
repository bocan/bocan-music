import Foundation
import Metadata
import Persistence
import Testing
@testable import Library

// MARK: - LyricsService tests

@Suite("LyricsService", .serialized)
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

    @Test("autoFetchIfMissing skips when lrclib consent is off")
    func autoFetchSkipsWithoutConsent() async throws {
        let db = try await makeDB()
        let spy = SpyFetcher(returnDoc: .unsynced("Would fetch"))
        let svc = self.makeService(db: db, fetcher: spy)
        let id = try await seedTrack(db: db)
        UserDefaults.standard.set(false, forKey: "lyrics.lrclibEnabled")

        let result = try await svc.autoFetchIfMissing(for: id)
        #expect(result == nil)
        #expect(!spy.wasCalled)
    }

    @Test("autoFetchIfMissing skips when lyrics already exist")
    func autoFetchSkipsWhenHasLyrics() async throws {
        let db = try await makeDB()
        let spy = SpyFetcher()
        let svc = self.makeService(db: db, fetcher: spy)
        let id = try await seedTrack(db: db)
        UserDefaults.standard.set(true, forKey: "lyrics.lrclibEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "lyrics.lrclibEnabled") }

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
        UserDefaults.standard.set(true, forKey: "lyrics.lrclibEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "lyrics.lrclibEnabled") }

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

// MARK: - Embed + sidecar (Phase 11 fileURL bugfix)

extension LyricsServiceTests {
    /// Copies a real MP3 from the sample-library fixture to a temp path and
    /// returns its URL. Caller owns cleanup.
    private func tempMP3() throws -> URL {
        guard let libraryURL = Bundle.module.url(
            forResource: "sample-library",
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            throw LibraryError.invalidFileURL("fixture sample-library missing")
        }
        let enumerator = FileManager.default.enumerator(at: libraryURL, includingPropertiesForKeys: nil)
        while let candidate = enumerator?.nextObject() as? URL {
            guard candidate.pathExtension == "mp3",
                  !candidate.lastPathComponent.lowercased().contains("corrupt") else { continue }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).mp3")
            try FileManager.default.copyItem(at: candidate, to: tmp)
            return tmp
        }
        throw LibraryError.invalidFileURL("no mp3 in sample-library")
    }

    @Test("persistToFile embeds through the edit pipeline and keeps the canonical source")
    func embedViaEditPipeline() async throws {
        let db = try await makeDB()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Production rows store URL strings, not paths.
        let trackID = try await seedTrack(db: db, fileURL: tmp.absoluteString)
        let editService = try MetadataEditService(database: db)
        let svc = LyricsService(database: db, fetcher: nil, editService: editService)

        try await svc.setLyrics(
            .unsynced("Here come old flat-top"),
            for: trackID,
            source: "lrclib",
            persistToFile: true
        )

        // File bytes carry the lyrics…
        let tags = try TagReader().read(from: tmp)
        #expect(tags.lyrics == "Here come old flat-top")

        // …and the DB row keeps its lrclib source (the edit pipeline's own
        // "user"-source row write must not be the last word).
        let row = try await LyricsRepository(database: db).fetch(trackID: trackID)
        #expect(row?.source == "lrclib")
    }

    @Test("forceFetch embeds only when embedInFile is set")
    func forceFetchHonoursEmbedFlag() async throws {
        let db = try await makeDB()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let trackID = try await seedTrack(db: db, fileURL: tmp.absoluteString)
        let editService = try MetadataEditService(database: db)
        let fetcher = SpyFetcher(returnDoc: .unsynced("Fetched words"))
        let svc = LyricsService(database: db, fetcher: fetcher, editService: editService)

        // Without the flag: DB only, file untouched.
        _ = try await svc.forceFetch(for: trackID)
        let before = try TagReader().read(from: tmp)
        #expect(before.lyrics == nil)

        // With the flag: embedded.
        _ = try await svc.forceFetch(for: trackID, embedInFile: true)
        let after = try TagReader().read(from: tmp)
        #expect(after.lyrics == "Fetched words")
    }

    @Test("sidecar .lrc resolves for URL-string file paths")
    func sidecarResolvesURLStringPaths() async throws {
        let db = try await makeDB()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let audioURL = dir.appendingPathComponent("song.flac")
        let lrcURL = dir.appendingPathComponent("song.lrc")
        try "[00:01.00]Sidecar line".write(to: lrcURL, atomically: true, encoding: .utf8)

        // The production shape: a URL string. URL(fileURLWithPath:) mangled
        // these into garbage relative paths, so sidecars never loaded.
        let trackID = try await seedTrack(db: db, fileURL: audioURL.absoluteString)
        let svc = self.makeService(db: db)

        let (doc, source) = try await svc.lyricsWithSource(for: trackID)
        #expect(source == "sidecar")
        guard case let .synced(lines, _) = doc else {
            Issue.record("expected synced sidecar document")
            return
        }
        #expect(lines.first?.text == "Sidecar line")
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
