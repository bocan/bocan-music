import Foundation
import Library
import Testing
@testable import Persistence
@testable import UI

// MARK: - LibraryRootRemovalFailureTests

/// A folder removal that fails must reach the listener (#645). Before, the
/// failure was only logged: the folder could be gone from the list while its
/// songs stayed, with no message.
@Suite("Library root removal failure")
@MainActor
struct LibraryRootRemovalFailureTests {
    @Test("a failed folder removal shows an error")
    func failedRemovalReachesTheListener() async throws {
        let db = try await Database(location: .inMemory)
        let vm = LibraryViewModel(database: db, engine: MockTransport(), scanner: LibraryScanner(database: db))
        // With no roots table, the scanner's first read throws.
        try await db.write { try $0.execute(sql: "DROP TABLE library_roots") }

        await vm.removeRoot(id: 1)

        let message = try #require(vm.playbackErrorMessage)
        #expect(message.hasPrefix("Could not remove the folder from the library: "))
    }

    @Test("a folder removal that works shows no error")
    func removalShowsNoError() async throws {
        let db = try await Database(location: .inMemory)
        let scanner = LibraryScanner(database: db)
        let vm = LibraryViewModel(database: db, engine: MockTransport(), scanner: scanner)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bocan-645-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await scanner.addRoot(folder)
        await vm.refreshRoots()
        let id = try #require(vm.libraryRoots.first?.id)

        await vm.removeRoot(id: id)

        #expect(vm.playbackErrorMessage == nil)
        #expect(vm.libraryRoots.isEmpty)
    }
}
