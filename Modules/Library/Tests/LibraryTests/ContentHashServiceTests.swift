import CryptoKit
import Foundation
import Persistence
import Testing
@testable import Library

@Suite("ContentHashService")
struct ContentHashServiceTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("content-hash-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `bytes` to a new file under `dir` and returns the track row for
    /// it (bookmark included), plus the expected lowercase-hex SHA-256.
    private func makeFileTrack(
        in dir: URL,
        name: String,
        bytes: Data
    ) throws -> (track: Track, expectedHash: String) {
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        let now = Int64(Date().timeIntervalSince1970)
        let track = try Track(
            fileURL: url.absoluteString,
            fileBookmark: LibraryLocation.bookmark(for: url),
            fileSize: Int64(bytes.count),
            fileMtime: now,
            fileFormat: "flac",
            duration: 1,
            title: name,
            addedAt: now,
            updatedAt: now
        )
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (track, expected)
    }

    @Test("sha256Hex streams a file to the same digest as a one-shot hash")
    func hashMatchesOneShot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Larger than one 1 MiB chunk so the loop iterates.
        var bytes = Data(count: (1 << 20) + 4096)
        bytes.withUnsafeMutableBytes { buffer in
            for i in 0 ..< buffer.count {
                buffer[i] = UInt8(truncatingIfNeeded: i &* 31)
            }
        }
        let url = dir.appendingPathComponent("big.bin")
        try bytes.write(to: url)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(try ContentHashService.sha256Hex(ofFileAt: url) == expected)
    }

    @Test("backfillOnce hashes every candidate and drains the missing count")
    func backfillHashesCandidates() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await makeDB()
        let repo = TrackRepository(database: db)

        let (a, hashA) = try makeFileTrack(in: dir, name: "a.flac", bytes: Data("first file".utf8))
        let (b, hashB) = try makeFileTrack(in: dir, name: "b.flac", bytes: Data("second file".utf8))
        let idA = try await repo.insert(a)
        let idB = try await repo.insert(b)

        let service = ContentHashService(tracks: repo)
        await service.backfillOnce()

        #expect(try await repo.fetch(id: idA).contentHash == hashA)
        #expect(try await repo.fetch(id: idB).contentHash == hashB)
        #expect(try await repo.countMissingContentHash() == 0)
    }

    @Test("a missing file is skipped once and does not block the rest of the pass")
    func missingFileSkipped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await makeDB()
        let repo = TrackRepository(database: db)

        let (gone, _) = try makeFileTrack(in: dir, name: "gone.flac", bytes: Data("doomed".utf8))
        let (kept, keptHash) = try makeFileTrack(in: dir, name: "kept.flac", bytes: Data("survives".utf8))
        let goneId = try await repo.insert(gone)
        let keptId = try await repo.insert(kept)
        try FileManager.default.removeItem(at: #require(URL(string: gone.fileURL)))

        let service = ContentHashService(tracks: repo)
        await service.backfillOnce()

        #expect(try await repo.fetch(id: goneId).contentHash == nil)
        #expect(try await repo.fetch(id: keptId).contentHash == keptHash)
        // The broken track is still missing, but the pass terminated anyway.
        #expect(try await repo.countMissingContentHash() == 1)
    }

    @Test("start() observes the library and hashes a track inserted later")
    func observationTriggersBackfill() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await makeDB()
        let repo = TrackRepository(database: db)

        let service = ContentHashService(tracks: repo, debounce: .milliseconds(20))
        await service.start()
        defer { Task { await service.stop() } }

        let (track, expected) = try makeFileTrack(in: dir, name: "late.flac", bytes: Data("added after start".utf8))
        let id = try await repo.insert(track)

        // Debounce plus hashing is fast; poll rather than sleep a fixed time.
        var hash: String?
        for _ in 0 ..< 200 {
            hash = try await repo.fetch(id: id).contentHash
            if hash != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(hash == expected)
    }

    @Test("backfillOnce paginates past a full batch of failures")
    func cursorPaginatesPastFailures() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await makeDB()
        let repo = TrackRepository(database: db)

        // Two broken files fill the first batch (batchSize: 2); the good file
        // sits behind them and must still be reached.
        for name in ["bad1.flac", "bad2.flac"] {
            let (broken, _) = try makeFileTrack(in: dir, name: name, bytes: Data("x".utf8))
            _ = try await repo.insert(broken)
            try FileManager.default.removeItem(at: #require(URL(string: broken.fileURL)))
        }
        let (good, goodHash) = try makeFileTrack(in: dir, name: "good.flac", bytes: Data("payload".utf8))
        let goodId = try await repo.insert(good)

        let service = ContentHashService(tracks: repo, batchSize: 2)
        await service.backfillOnce()

        #expect(try await repo.fetch(id: goodId).contentHash == goodHash)
        #expect(try await repo.countMissingContentHash() == 2)
    }
}
