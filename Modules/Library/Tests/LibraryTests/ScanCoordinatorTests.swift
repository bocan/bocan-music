import Foundation
import Metadata
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

/// Thread-safe event accumulator for use in @Sendable scan callbacks.
private final class EventBox: @unchecked Sendable {
    var events: [ScanProgress] = []
    func append(_ event: ScanProgress) {
        self.events.append(event)
    }
}

// MARK: - ScanCoordinator tests

@Suite("ScanCoordinator")
struct ScanCoordinatorTests {
    // MARK: - Basic scan

    @Test("scan over empty root list emits started then finished")
    func scanEmptyRoots() async throws {
        let db = try await makeDB()
        let coordinator = ScanCoordinator(database: db)

        let box = EventBox()
        await coordinator.scan(roots: [], mode: .full) { box.append($0) }
        let events = box.events

        let hasStarted = events.contains { if case .started = $0 { return true }
            return false
        }
        let hasFinished = events.contains { if case .finished = $0 { return true }
            return false
        }
        #expect(hasStarted)
        #expect(hasFinished)

        if case let .finished(summary) = events.last {
            #expect(summary.inserted == 0)
            #expect(summary.errors == 0)
        }
    }

    @Test("full scan inserts tracks for all audio files in sample-library")
    func fullScanInsertsAllTracks() async throws {
        let db = try await makeDB()
        let coordinator = ScanCoordinator(database: db)
        let dir = try sampleLibraryURL

        await coordinator.scan(roots: [(url: dir, rootID: 1)], mode: .full) { _ in }

        let trackRepo = TrackRepository(database: db)
        let count = try await trackRepo.count()
        #expect(count >= 10, "Expected >= 10 tracks from sample-library, got \(count)")
    }

    @Test("full scan emits processed event for each audio file")
    func fullScanEmitsProcessedEvents() async throws {
        let db = try await makeDB()
        let coordinator = ScanCoordinator(database: db)
        let dir = try sampleLibraryURL

        let box = EventBox()
        await coordinator.scan(roots: [(url: dir, rootID: 1)], mode: .full) { box.append($0) }
        let processed = box.events.count(where: { if case .processed = $0 { return true }
            return false
        })

        #expect(processed >= 10)
    }

    @Test("full scan summary inserted count matches processed count")
    func summaryCountMatchesProcessed() async throws {
        let db = try await makeDB()
        let coordinator = ScanCoordinator(database: db)
        let dir = try sampleLibraryURL

        let box = EventBox()
        await coordinator.scan(roots: [(url: dir, rootID: 1)], mode: .full) { box.append($0) }
        let events = box.events

        let inserted = events.count(where: {
            if case .processed(_, outcome: .inserted) = $0 { return true }
            return false
        })

        guard case let .finished(summary) = events.last else {
            Issue.record("Last event was not .finished")
            return
        }
        #expect(summary.inserted == inserted)
    }

    // MARK: - Quick scan

    @Test("quick scan after full scan skips unchanged files")
    func quickScanSkipsUnchanged() async throws {
        let db = try await makeDB()
        let coordinator = ScanCoordinator(database: db)
        let dir = try sampleLibraryURL

        // First: full scan
        await coordinator.scan(roots: [(url: dir, rootID: 1)], mode: .full) { _ in }

        // Second: quick scan — everything should be skipped
        let box = EventBox()
        await coordinator.scan(roots: [(url: dir, rootID: 1)], mode: .quick) { box.append($0) }
        let skipped = box.events.count(where: {
            if case .processed(_, outcome: .skippedUnchanged) = $0 { return true }
            return false
        })
        #expect(skipped > 0)
    }

    @Test("quick scan summary reports zero inserted on unchanged library")
    func quickScanSummaryZeroInserts() async throws {
        let db = try await makeDB()
        let coordinator = ScanCoordinator(database: db)
        let dir = try sampleLibraryURL

        await coordinator.scan(roots: [(url: dir, rootID: 1)], mode: .full) { _ in }

        let box = EventBox()
        await coordinator.scan(roots: [(url: dir, rootID: 1)], mode: .quick) { box.append($0) }
        let summary: ScanProgress.Summary? = box.events.compactMap {
            if case let .finished(s) = $0 { return s }
            return nil
        }.first

        #expect(summary?.inserted == 0)
    }

    // MARK: - Removed files

    @Test("quick scan marks removed files disabled")
    func quickScanMarksRemovedDisabled() async throws {
        let db = try await makeDB()
        let coordinator = ScanCoordinator(database: db)

        // Use a temp directory we can manipulate; resolve symlinks so stored
        // and lookup URLs match (macOS /var → /private/var symlink).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Copy one fixture file in
        let fixture = try sampleLibraryURL
            .appendingPathComponent("Artist A/Album One/01 - First Track.mp3")
        let dest = tmp.appendingPathComponent("track.mp3")
        try FileManager.default.copyItem(at: fixture, to: dest)

        // Full scan to register it
        await coordinator.scan(roots: [(url: tmp, rootID: 1)], mode: .full) { _ in }
        let trackRepo = TrackRepository(database: db)
        let before = try await trackRepo.count()
        #expect(before == 1)

        // Remove the file and run a quick scan
        try FileManager.default.removeItem(at: dest)
        let box = EventBox()
        await coordinator.scan(roots: [(url: tmp, rootID: 1)], mode: .quick) { box.append($0) }
        let removedEvents: [Int64] = box.events.compactMap {
            if case let .removed(id) = $0 { return id }
            return nil
        }

        #expect(removedEvents.count == 1, "Expected one removed event, got \(removedEvents.count)")
        // Row should still exist but be marked disabled
        let allTracks = try await trackRepo.fetchAllIncludingDisabled()
        let disabledTrack = allTracks.first { $0.disabled }
        #expect(disabledTrack != nil, "Expected the removed track to be marked disabled in the DB")
    }

    // MARK: - Error handling

    @Test("corrupt/zero-byte file does not crash scan; valid files still import")
    func corruptFileDoesNotCrashScan() async throws {
        let db = try await makeDB()
        let coordinator = ScanCoordinator(database: db)
        let dir = try sampleLibraryURL.appendingPathComponent("EdgeCases")

        let box = EventBox()
        await coordinator.scan(roots: [(url: dir, rootID: 1)], mode: .full) { box.append($0) }
        let errors = box.events.count(where: { if case .error = $0 { return true }
            return false
        })
        let inserted = box.events.count(where: {
            if case .processed(_, outcome: .inserted) = $0 { return true }
            return false
        })

        // Scan must complete (no hang); at least the valid EdgeCase files are processed
        #expect(inserted >= 1, "Expected at least one successful import from EdgeCases")
        // Errors are acceptable but not required — depends on TagReader leniency
        _ = errors
    }

    @Test("unicode filename imports without error")
    func unicodeFilenameImports() async throws {
        let db = try await makeDB()
        let coordinator = ScanCoordinator(database: db)
        let dir = try sampleLibraryURL.appendingPathComponent("EdgeCases")

        let box = EventBox()
        await coordinator.scan(roots: [(url: dir, rootID: 1)], mode: .full) { box.append($0) }
        let events = box.events

        let unicodeInserted = events.contains { event in
            if case let .processed(url, outcome: .inserted) = event {
                return url.lastPathComponent.contains("こんにちは世界")
            }
            return false
        }
        #expect(unicodeInserted, "Unicode-named FLAC should import successfully")
    }

    // MARK: - Multi-root scan

    @Test("scan over multiple roots accumulates tracks from all roots")
    func multiRootScan() async throws {
        let db = try await makeDB()
        let coordinator = ScanCoordinator(database: db)
        let artistA = try sampleLibraryURL.appendingPathComponent("Artist A")
        let artistB = try sampleLibraryURL.appendingPathComponent("Artist B")

        await coordinator.scan(
            roots: [(url: artistA, rootID: 1), (url: artistB, rootID: 2)],
            mode: .full
        ) { _ in }

        let trackRepo = TrackRepository(database: db)
        let count = try await trackRepo.count()
        // Artist A has 3 tracks; Artist B has 2
        #expect(count >= 4, "Expected tracks from both roots, got \(count)")
    }
}
