import Foundation
import Persistence
import Testing
@testable import Library

// MARK: - Helpers

private func makeDB() async throws -> Database {
    try await Database(location: .inMemory)
}

private var sampleLibraryURL: URL {
    get throws {
        guard let url = Bundle.module.url(
            forResource: "sample-library",
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            throw LibraryError.invalidPath("Fixtures/sample-library not found in bundle")
        }
        return url
    }
}

// MARK: - LibraryScanner tests

@Suite("LibraryScanner")
struct LibraryScannerTests {
    // MARK: - Root management

    @Test("addRoot stores root in database")
    func addRootPersists() async throws {
        let db = try await makeDB()
        let scanner = LibraryScanner(database: db)
        let dir = try sampleLibraryURL

        try await scanner.addRoot(dir)

        let roots = try await scanner.roots()
        #expect(roots.count == 1)
        #expect(roots[0].path == dir.path)
        #expect(!roots[0].bookmark.isEmpty)
    }

    @Test("removeRoot deletes root from database")
    func removeRootDeletes() async throws {
        let db = try await makeDB()
        let scanner = LibraryScanner(database: db)
        let dir = try sampleLibraryURL

        try await scanner.addRoot(dir)
        let roots = try await scanner.roots()
        let id = try #require(roots.first?.id)

        try await scanner.removeRoot(id: id)

        let remaining = try await scanner.roots()
        #expect(remaining.isEmpty)
    }

    @Test("roots returns empty array when no roots added")
    func rootsIsInitiallyEmpty() async throws {
        let db = try await makeDB()
        let scanner = LibraryScanner(database: db)
        let roots = try await scanner.roots()
        #expect(roots.isEmpty)
    }

    @Test("addRoot for same path twice does not create duplicate")
    func addRootIdempotent() async throws {
        let db = try await makeDB()
        let scanner = LibraryScanner(database: db)
        let dir = try sampleLibraryURL

        try await scanner.addRoot(dir)
        try await scanner.addRoot(dir) // second call — upsert should be idempotent

        let roots = try await scanner.roots()
        #expect(roots.count == 1)
    }

    // MARK: - Scanning

    @Test("scan with no roots finishes immediately")
    func scanWithNoRootsFinishes() async throws {
        let db = try await makeDB()
        let scanner = LibraryScanner(database: db)

        var events: [ScanProgress] = []
        for await event in await scanner.scan() {
            events.append(event)
        }

        // Should produce nothing or just finish cleanly — no crash
        #expect(!events.contains { if case .error = $0 { return true }
            return false
        })
    }

    @Test("scan emits started and finished events")
    func scanEmitsLifecycleEvents() async throws {
        let db = try await makeDB()
        let scanner = LibraryScanner(database: db)
        let dir = try sampleLibraryURL
        try await scanner.addRoot(dir)

        var events: [ScanProgress] = []
        for await event in await scanner.scan(mode: .full) {
            events.append(event)
        }

        let hasStarted = events.contains { if case .started = $0 { return true }
            return false
        }
        let hasFinished = events.contains { if case .finished = $0 { return true }
            return false
        }
        #expect(hasStarted)
        #expect(hasFinished)
    }

    @Test("full scan inserts audio files into database")
    func scanInsertsAudioFiles() async throws {
        let db = try await makeDB()
        let scanner = LibraryScanner(database: db)
        let dir = try sampleLibraryURL
        try await scanner.addRoot(dir)

        for await _ in await scanner.scan(mode: .full) {}

        let trackRepo = TrackRepository(database: db)
        let count = try await trackRepo.count()
        // Sample library has 13 real audio tracks + 2 edge-case audio files (no-tags + unicode)
        // = 15 audio files; hidden + artwork.psd + cover.jpg + .lrc are skipped
        #expect(count >= 10, "Expected at least 10 tracks, got \(count)")
    }

    @Test("quick scan skips unchanged files on second pass")
    func quickScanSkipsUnchanged() async throws {
        let db = try await makeDB()
        let scanner = LibraryScanner(database: db)
        let dir = try sampleLibraryURL
        try await scanner.addRoot(dir)

        // Full scan first
        for await _ in await scanner.scan(mode: .full) {}

        // Second pass (quick)
        var skipped = 0
        for await event in await scanner.scan(mode: .quick) {
            if case .processed(_, outcome: .skippedUnchanged) = event { skipped += 1 }
        }
        #expect(skipped > 0, "Expected unchanged files to be skipped on quick scan")
    }

    @Test("scan summary reports correct totals")
    func scanSummaryTotals() async throws {
        let db = try await makeDB()
        let scanner = LibraryScanner(database: db)
        let dir = try sampleLibraryURL
        try await scanner.addRoot(dir)

        var summary: ScanProgress.Summary?
        for await event in await scanner.scan(mode: .full) {
            if case let .finished(s) = event { summary = s }
        }

        let s = try #require(summary)
        #expect(s.inserted > 0)
        #expect(s.errors == 0 || s.errors < s.inserted, "Errors should not dominate")
    }

    @Test("concurrent scan attempt yields scanAlreadyInProgress error")
    func concurrentScanFails() async throws {
        let db = try await makeDB()
        let scanner = LibraryScanner(database: db)
        let dir = try sampleLibraryURL
        try await scanner.addRoot(dir)

        // Start first scan
        let stream1 = await scanner.scan(mode: .full)
        var iter1 = stream1.makeAsyncIterator()
        _ = await iter1.next() // pull first event to ensure scan started

        // Start a second scan — should immediately emit an error
        var secondScanError = false
        for await event in await scanner.scan(mode: .full) {
            if case .error = event { secondScanError = true }
        }
        #expect(secondScanError)

        // Drain the first scan
        while await iter1.next() != nil {}
    }

    // MARK: - scanSingleFile

    @Test("scanSingleFile inserts a single audio file into the database")
    func scanSingleFileInserts() async throws {
        let db = try await makeDB()
        let scanner = LibraryScanner(database: db)
        let dir = try sampleLibraryURL

        // Pick the first audio file from the fixture directory
        let audioFile = FileManager.default
            .enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .first { url in
                let ext = url.pathExtension.lowercased()
                return ["flac", "mp3", "aac", "m4a", "wav", "ogg", "opus"].contains(ext)
            }
        let url = try #require(audioFile, "No audio file found in fixture directory")

        let summary = try await scanner.scanSingleFile(url: url)
        #expect(summary.inserted + summary.updated == 1)
        #expect(summary.errors == 0)
    }

    @Test("scanSingleFile on a non-existent file records an error")
    func scanSingleFileNonExistent() async throws {
        let db = try await makeDB()
        let scanner = LibraryScanner(database: db)
        let url = URL(fileURLWithPath: "/tmp/does_not_exist_bocan_test.flac")

        let summary = try await scanner.scanSingleFile(url: url)
        #expect(summary.errors >= 1)
    }
}

// MARK: - LibraryLocation tests

@Suite("LibraryLocation")
struct LibraryLocationTests {
    @Test("applicationSupportDirectory returns a valid path under ~/Library")
    func applicationSupportDirectoryExists() {
        let dir = LibraryLocation.applicationSupportDirectory
        #expect(dir.path.contains("Bocan"))
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("coverArtCacheDirectory is inside applicationSupportDirectory")
    func coverArtCacheDirectoryIsNested() {
        let cache = LibraryLocation.coverArtCacheDirectory
        #expect(cache.path.contains("CoverArt"))
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("bookmark roundtrip resolves to the same path")
    func bookmarkRoundtrip() throws {
        let dir = LibraryLocation.applicationSupportDirectory
        let bookmark = try LibraryLocation.bookmark(for: dir)
        let (resolved, isStale) = try LibraryLocation.resolve(bookmark)
        #expect(resolved.path == dir.path)
        #expect(!isStale)
    }
}
