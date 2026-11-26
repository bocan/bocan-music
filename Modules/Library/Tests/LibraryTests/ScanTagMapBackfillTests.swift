import Foundation
import Metadata
import Persistence
import Testing
@testable import Library

/// #735: `tracks.extended_tags` must catch up with the file for rows the scan
/// used to leave alone: an unchanged file whose row never stored the map
/// (quick scan), and a user-edited row (both full-scan paths).
@Suite("Scan tag map upkeep")
struct ScanTagMapBackfillTests {
    /// A temp root holding one tagged fixture MP3, already full-scanned.
    private struct Scanned {
        let coordinator: ScanCoordinator
        let root: URL
        let file: URL
        let repo: TrackRepository

        /// The root's only track. Read without a URL lookup: the scan stores
        /// the `realpath` form (/private/var/...), which no Foundation URL
        /// call on the temp path reliably reproduces.
        func row() async throws -> Track {
            let rows = try await self.repo.fetchAllIncludingDisabled()
            #expect(rows.count == 1)
            return try #require(rows.first)
        }

        func scan(_ mode: ScanMode) async {
            await self.coordinator.scan(roots: [(url: self.root, rootID: 1)], mode: mode) { _ in }
        }

        /// The tag map read straight from the file, decoded.
        func fileMap() throws -> [String: [String]] {
            try TagReader().read(from: self.file).extendedTags
        }
    }

    private func makeScanned() async throws -> Scanned {
        let db = try await Database(location: .inMemory)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let library = Bundle.module.url(forResource: "sample-library", withExtension: nil, subdirectory: "Fixtures") else {
            throw LibraryError.invalidPath("Fixtures/sample-library not found in bundle")
        }
        let file = root.appendingPathComponent("track.mp3")
        try FileManager.default.copyItem(
            at: library.appendingPathComponent("Artist A/Album One/01 - First Track.mp3"),
            to: file
        )
        let scanned = Scanned(
            coordinator: ScanCoordinator(database: db),
            root: root,
            file: file,
            repo: TrackRepository(database: db)
        )
        await scanned.scan(.full)
        return scanned
    }

    private func decoded(_ json: String?) throws -> [String: [String]] {
        try JSONDecoder().decode([String: [String]].self, from: Data(#require(json).utf8))
    }

    // MARK: - Quick scan backfill

    @Test("a quick scan fills a missing tag map once and leaves the user's edit alone")
    func quickScanBackfillsMissingTagMap() async throws {
        let scanned = try await makeScanned()
        defer { try? FileManager.default.removeItem(at: scanned.root) }
        #expect(try !(scanned.fileMap().isEmpty), "the fixture must carry tags for this test to mean anything")

        // The state #735 found: edited in Get Info before the editor wrote
        // the map, file untouched since.
        var edited = try await scanned.row()
        edited.title = "My Edit"
        edited.userEdited = true
        edited.extendedTags = nil
        try await scanned.repo.update(edited)

        await scanned.scan(.quick)

        let after = try await scanned.row()
        #expect(try self.decoded(after.extendedTags) == scanned.fileMap())
        #expect(after.title == "My Edit")
        #expect(after.userEdited)
        #expect(!after.needsConflictReview, "an unchanged file is never a conflict")
    }

    @Test("a quick scan does not read a file whose row already has a tag map")
    func quickScanLeavesAnExistingTagMap() async throws {
        let scanned = try await makeScanned()
        defer { try? FileManager.default.removeItem(at: scanned.root) }

        var row = try await scanned.row()
        row.extendedTags = #"{"SENTINEL":["kept"]}"#
        try await scanned.repo.update(row)

        await scanned.scan(.quick)

        #expect(try await scanned.row().extendedTags == #"{"SENTINEL":["kept"]}"#)
    }

    // MARK: - Full scan, user-edited rows

    @Test("a full scan refreshes the tag map of a user-edited row (conflict path)")
    func fullScanRefreshesUserEditedTagMap() async throws {
        let scanned = try await makeScanned()
        defer { try? FileManager.default.removeItem(at: scanned.root) }

        var edited = try await scanned.row()
        #expect(edited.albumID != nil, "takes the conflict path only with an album")
        edited.userEdited = true
        edited.extendedTags = #"{"STALE":["map"]}"#
        try await scanned.repo.update(edited)

        await scanned.scan(.full)

        #expect(try await self.decoded(scanned.row().extendedTags) == scanned.fileMap())
    }

    @Test("a full scan refreshes the tag map of a user-edited row with no album (importer path)")
    func fullScanRefreshesAlbumlessUserEditedTagMap() async throws {
        let scanned = try await makeScanned()
        defer { try? FileManager.default.removeItem(at: scanned.root) }

        var edited = try await scanned.row()
        edited.userEdited = true
        edited.albumID = nil
        edited.extendedTags = #"{"STALE":["map"]}"#
        try await scanned.repo.update(edited)

        await scanned.scan(.full)

        let after = try await scanned.row()
        #expect(try self.decoded(after.extendedTags) == scanned.fileMap())
        #expect(after.userEdited)
    }
}
