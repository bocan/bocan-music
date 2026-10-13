import Foundation
import Persistence
import Testing
@testable import Library

// MARK: - Helpers

/// A real audio file from the checked-in fixtures.
private func fixtureTrack() throws -> URL {
    let library = try #require(Bundle.module.url(
        forResource: "sample-library",
        withExtension: nil,
        subdirectory: "Fixtures"
    ))
    return library.appendingPathComponent("Artist A/Album One/03 - Third Track.flac")
}

private func makeScratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bocan-sources-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Copies the fixture track to `folder/name`, creating the folder.
private func copyTrack(to folder: URL, name: String = "song.flac") throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appendingPathComponent(name)
    try FileManager.default.copyItem(at: fixtureTrack(), to: destination)
    return destination
}

private func finishedSummary(of scanner: LibraryScanner) async -> ScanProgress.Summary? {
    var summary: ScanProgress.Summary?
    for await event in await scanner.scan() {
        if case let .finished(result) = event {
            summary = result
        }
    }
    return summary
}

// MARK: - LibrarySourceBoundaryTests

/// The library takes in only what a music source holds: a folder-watcher
/// event outside every source imports nothing (#643), and a single-file source
/// behaves across scans as a file in a folder does (#646).
@Suite("Library source boundary")
struct LibrarySourceBoundaryTests {
    // MARK: - Folder-watcher events

    @Test("a watcher event for a file outside every root imports nothing")
    func eventOutsideRootsIsDropped() async throws {
        let db = try await Database(location: .inMemory)
        let scanner = LibraryScanner(database: db)
        let tracks = TrackRepository(database: db)
        let drive = try makeScratch()
        let inside = try copyTrack(to: drive.appendingPathComponent("Music/Album"))
        // A sibling of the root, as "16-bit albums to be processed" was.
        let outside = try copyTrack(to: drive.appendingPathComponent("Music to be processed/Album"))
        try await scanner.addRoot(drive.appendingPathComponent("Music", isDirectory: true))

        await scanner.handleFSChange(urls: [outside, outside.deletingLastPathComponent(), inside])

        #expect(try await tracks.fetchOne(fileURL: outside.absoluteString) == nil)
        #expect(try await tracks.fetchOne(fileURL: inside.absoluteString) != nil)
        #expect(try await tracks.count() == 1)
    }

    @Test("a watcher event beside a single-file root imports only that file")
    func eventBesideFileRootIsDropped() async throws {
        let db = try await Database(location: .inMemory)
        let scanner = LibraryScanner(database: db)
        let tracks = TrackRepository(database: db)
        let folder = try makeScratch()
        let added = try copyTrack(to: folder, name: "added.flac")
        let neighbour = try copyTrack(to: folder, name: "neighbour.flac")
        try await scanner.addRoot(added)

        await scanner.handleFSChange(urls: [neighbour, added])

        #expect(try await tracks.fetchOne(fileURL: neighbour.absoluteString) == nil)
        #expect(try await tracks.fetchOne(fileURL: added.absoluteString) != nil)
    }

    @Test("a watcher event for a deleted folder outside every root hides nothing")
    func removalOutsideRootsIsDropped() async throws {
        let db = try await Database(location: .inMemory)
        let scanner = LibraryScanner(database: db)
        let tracks = TrackRepository(database: db)
        let drive = try makeScratch()
        _ = try copyTrack(to: drive.appendingPathComponent("Music"))
        try await scanner.addRoot(drive.appendingPathComponent("Music", isDirectory: true))
        let gone = drive.appendingPathComponent("Elsewhere", isDirectory: true)
        let id = try await tracks.insert(Track(
            fileURL: gone.appendingPathComponent("1.flac").absoluteString,
            fileSize: 1,
            fileMtime: 1,
            fileFormat: "flac",
            duration: 1,
            title: "T",
            addedAt: 1,
            updatedAt: 1
        ))

        await scanner.handleFSChange(urls: [gone])

        #expect(try await !tracks.fetch(id: id).disabled)
    }

    // MARK: - Single-file roots across scans

    @Test("an unchanged single-file root is read once, then skipped")
    func fileRootIsSkippedWhenUnchanged() async throws {
        let db = try await Database(location: .inMemory)
        let scanner = LibraryScanner(database: db)
        try await scanner.addRoot(copyTrack(to: makeScratch()))

        let first = try #require(await finishedSummary(of: scanner))
        let second = try #require(await finishedSummary(of: scanner))

        #expect(first.inserted == 1)
        #expect(second.inserted == 0)
        #expect(second.updated == 0, "an unchanged file must not be read again")
        #expect(second.skipped == 1)
        #expect(second.removed == 0)
    }

    @Test("a single-file root whose file was deleted goes, and its track is hidden")
    func deletedFileRootIsRemoved() async throws {
        let db = try await Database(location: .inMemory)
        let scanner = LibraryScanner(database: db)
        let tracks = TrackRepository(database: db)
        let file = try copyTrack(to: makeScratch())
        try await scanner.addRoot(file)
        _ = await finishedSummary(of: scanner)
        // The scan stores the path the bookmark resolves to, which need not
        // be spelled as `file` is (`/var` and `/private/var`).
        let id = try #require(try await tracks.enabledFileURLs().keys.first)

        try FileManager.default.removeItem(at: file)
        let summary = try #require(await finishedSummary(of: scanner))

        #expect(summary.removed == 1)
        #expect(try await tracks.fetch(id: id).disabled)
        #expect(try await scanner.roots().isEmpty)
    }

    @Test("a single-file root on a drive that is not connected stays, with its track")
    func unreachableFileRootIsKept() async throws {
        let db = try await Database(location: .inMemory)
        let scanner = LibraryScanner(database: db)
        let tracks = TrackRepository(database: db)
        let folder = try makeScratch()
        let file = try copyTrack(to: folder)
        try await scanner.addRoot(file)
        _ = await finishedSummary(of: scanner)
        // The scan stores the path the bookmark resolves to, which need not
        // be spelled as `file` is (`/var` and `/private/var`).
        let id = try #require(try await tracks.enabledFileURLs().keys.first)

        // The folder goes with the file, as it does when a drive is unplugged.
        try FileManager.default.removeItem(at: folder)
        let summary = try #require(await finishedSummary(of: scanner))

        #expect(summary.removed == 0)
        #expect(try await !tracks.fetch(id: id).disabled)
        #expect(try await scanner.roots().count == 1)
    }
}
