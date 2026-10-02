import Foundation
import Persistence
import Testing
@testable import Library

// MARK: - Roots whose path is a prefix of another root's path (#621)

/// A scan of the root `Music` must not touch the tracks of the root `Music2`.
///
/// The scan seeds its change detector with the stored tracks under the roots
/// it is about to walk, and reports every seeded track the walk did not visit
/// as removed. When the seed chose tracks with a bare path prefix, a scan of
/// `Music` alone also seeded the tracks of `Music2`, did not visit them, and
/// disabled them.
@Suite("Scan of a root that is a path prefix of another root")
struct ScanRootPrefixTests {
    private var fixtureTrack: URL {
        get throws {
            guard let library = Bundle.module.url(
                forResource: "sample-library",
                withExtension: nil,
                subdirectory: "Fixtures"
            ) else {
                throw LibraryError.invalidPath("Fixtures/sample-library not found in bundle")
            }
            return library.appendingPathComponent("Artist A/Album One/01 - First Track.mp3")
        }
    }

    @Test("a scan of Music leaves every track of Music2 enabled")
    func scanOfMusicLeavesMusic2Enabled() async throws {
        let db = try await Database(location: .inMemory)
        let coordinator = ScanCoordinator(database: db)

        // Resolve symlinks so stored and lookup URLs match (/var -> /private/var).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        let music = tmp.appendingPathComponent("Music", isDirectory: true)
        let music2 = tmp.appendingPathComponent("Music2", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: music2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.copyItem(at: self.fixtureTrack, to: music.appendingPathComponent("one.mp3"))
        try FileManager.default.copyItem(at: self.fixtureTrack, to: music2.appendingPathComponent("two.mp3"))

        // Both roots are scanned once, so both tracks are in the library.
        await coordinator.scan(roots: [(url: music, rootID: 1), (url: music2, rootID: 2)], mode: .full) { _ in }
        let trackRepo = TrackRepository(database: db)
        let before = try await trackRepo.fetchAllIncludingDisabled()
        #expect(before.count == 2)
        #expect(Set(before.map(\.disabled)) == [false])

        // A scan of Music alone, in each mode.
        for mode in [ScanMode.quick, ScanMode.full] {
            await coordinator.scan(roots: [(url: music, rootID: 1)], mode: mode) { _ in }
            let after = try await trackRepo.fetchAllIncludingDisabled()
            let disabled = after.filter(\.disabled).map(\.fileURL)
            #expect(disabled.isEmpty, "a \(mode) scan of Music disabled: \(disabled)")
        }
    }
}
