import Foundation
import Persistence
import Testing
@testable import Library

// MARK: - Helpers

/// A scratch folder whose name has a space, as external volumes often do: the
/// space is what makes the stored `file_url` differ from the plain path.
private func makeFolder(_ name: String = "lib root") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bocan-643-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeTrack(_ fileURL: String, albumID: Int64? = nil) -> Track {
    Track(
        fileURL: fileURL,
        fileSize: 1024,
        fileMtime: 1_700_000_000,
        fileFormat: "flac",
        duration: 180,
        title: "T",
        albumID: albumID,
        addedAt: 1_700_000_000,
        updatedAt: 1_700_000_000
    )
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

// MARK: - LibraryRootRemovalTests

/// Removing a music source hides its tracks, and a scan hides tracks that no
/// source holds (#643).
@Suite("Library root removal")
struct LibraryRootRemovalTests {
    // MARK: - removeRoot

    @Test("removeRoot hides the tracks in that folder, keeps the rest, and prunes its album")
    func removeRootHidesItsTracks() async throws {
        let db = try await Database(location: .inMemory)
        let scanner = LibraryScanner(database: db)
        let tracks = TrackRepository(database: db)
        let albums = AlbumRepository(database: db)
        let old = try makeFolder("old volume")
        let new = try makeFolder("new volume")
        try await scanner.addRoot(old)
        try await scanner.addRoot(new)
        let oldAlbum = try #require(try await albums.findOrCreate(title: "Only On Old", albumArtistID: nil).id)
        let shared = try #require(try await albums.findOrCreate(title: "Moved", albumArtistID: nil).id)
        let oldOnly = try await tracks.insert(makeTrack(old.appendingPathComponent("a b/1.flac").absoluteString, albumID: oldAlbum))
        let oldCopy = try await tracks.insert(makeTrack(old.appendingPathComponent("m/1.flac").absoluteString, albumID: shared))
        let newCopy = try await tracks.insert(makeTrack(new.appendingPathComponent("m/1.flac").absoluteString, albumID: shared))

        let oldRootID = try #require(try await scanner.roots().first { $0.path == old.path }?.id)
        try await scanner.removeRoot(id: oldRootID)

        #expect(try await tracks.fetch(id: oldOnly).disabled)
        #expect(try await tracks.fetch(id: oldCopy).disabled)
        #expect(try await !tracks.fetch(id: newCopy).disabled, "the copy in the folder that stays is untouched")
        #expect(try await albums.fetchAll().map(\.title) == ["Moved"], "an album with no visible track left is pruned")
        #expect(try await scanner.roots().map(\.path) == [new.path])
    }

    @Test("removeRoot keeps a track that a nested root still holds")
    func removeRootKeepsNestedRootTracks() async throws {
        let db = try await Database(location: .inMemory)
        let scanner = LibraryScanner(database: db)
        let tracks = TrackRepository(database: db)
        let parent = try makeFolder("Music")
        let child = parent.appendingPathComponent("Jazz", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try await scanner.addRoot(parent)
        try await scanner.addRoot(child)
        let inParent = try await tracks.insert(makeTrack(parent.appendingPathComponent("rock/1.flac").absoluteString))
        let inChild = try await tracks.insert(makeTrack(child.appendingPathComponent("1.flac").absoluteString))

        let parentID = try #require(try await scanner.roots().first { $0.path == parent.path }?.id)
        try await scanner.removeRoot(id: parentID)

        #expect(try await tracks.fetch(id: inParent).disabled)
        #expect(try await !tracks.fetch(id: inChild).disabled)
    }

    @Test("removeRoot hides the track of a single-file root")
    func removeRootHidesFileRoot() async throws {
        let db = try await Database(location: .inMemory)
        let scanner = LibraryScanner(database: db)
        let tracks = TrackRepository(database: db)
        let file = try makeFolder().appendingPathComponent("one song.flac")
        try Data().write(to: file)
        try await scanner.addRoot(file)
        let id = try await tracks.insert(makeTrack(file.absoluteString))

        let rootID = try #require(try await scanner.roots().first?.id)
        try await scanner.removeRoot(id: rootID)

        #expect(try await tracks.fetch(id: id).disabled)
    }

    // MARK: - Tracks outside every root

    @Test("a scan hides a local track that no root holds and reports it as removed")
    func scanHidesTracksOutsideRoots() async throws {
        let db = try await Database(location: .inMemory)
        let scanner = LibraryScanner(database: db)
        let tracks = TrackRepository(database: db)
        try await scanner.addRoot(makeFolder())
        // A root on a drive that is not connected: its bookmark cannot be
        // resolved, but its tracks still belong to it.
        try await LibraryRootRepository(database: db).upsert(LibraryRoot(
            path: "/Volumes/Unplugged 643/Music",
            bookmark: Data([0x00]),
            addedAt: 0
        ))
        let leftBehind = try await tracks.insert(makeTrack("file:///Volumes/Old%20643/Music/1.flac"))
        let unplugged = try await tracks.insert(makeTrack("file:///Volumes/Unplugged%20643/Music/1.flac"))
        let remote = try await tracks.insert(makeTrack("https://example.test/stream.mp3"))

        let summary = try #require(await finishedSummary(of: scanner))

        #expect(summary.removed == 1)
        #expect(try await tracks.fetch(id: leftBehind).disabled)
        #expect(try await !tracks.fetch(id: unplugged).disabled, "an unreachable root still holds its tracks")
        #expect(try await !tracks.fetch(id: remote).disabled, "a track that is not a local file is never touched")
    }

    @Test("with no reachable root the scan still hides left-behind tracks")
    func scanWithNoReachableRootHidesOrphans() async throws {
        let db = try await Database(location: .inMemory)
        let scanner = LibraryScanner(database: db)
        let tracks = TrackRepository(database: db)
        let leftBehind = try await tracks.insert(makeTrack("file:///Volumes/Old%20643/Music/1.flac"))

        let summary = try #require(await finishedSummary(of: scanner))

        #expect(summary.removed == 1)
        #expect(try await tracks.fetch(id: leftBehind).disabled)
    }
}

// MARK: - RootCoverageTests

@Suite("RootCoverage")
struct RootCoverageTests {
    @Test("a folder root holds files inside it, on whole path components")
    func folderRoot() {
        let coverage = RootCoverage(paths: ["/Volumes/external volume/Music"])
        #expect(coverage.position(ofFileURL: "file:///Volumes/external%20volume/Music/a/1.flac") == .inside)
        #expect(coverage.position(ofFileURL: "file:///Volumes/external%20volume/Music2/1.flac") == .outside)
        #expect(coverage.position(ofFileURL: "file:///Volumes/external%20volume/16-bit/1.flac") == .outside)
    }

    @Test("a trailing slash on the root changes nothing")
    func trailingSlash() {
        let coverage = RootCoverage(paths: ["/m/Music/"])
        #expect(coverage.position(ofFileURL: "file:///m/Music/1.flac") == .inside)
    }

    @Test("a single-file root holds exactly that file")
    func fileRoot() {
        let coverage = RootCoverage(paths: ["/m/one song.flac"])
        #expect(coverage.position(ofFileURL: "file:///m/one%20song.flac") == .inside)
        #expect(coverage.position(ofFileURL: "file:///m/other.flac") == .outside)
    }

    @Test("a track that is not a local file has no position among the roots")
    func notLocal() {
        let coverage = RootCoverage(paths: ["/m"])
        #expect(coverage.position(ofFileURL: "https://example.test/m/1.mp3") == .notLocal)
        #expect(coverage.position(ofFileURL: "") == .notLocal)
    }

    @Test("a root and a track that name the same folder through a symlink still match")
    func symlinkedRoot() throws {
        let real = try makeFolder("real")
        let link = real.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let file = real.appendingPathComponent("1.flac")
        try Data().write(to: file)

        let coverage = RootCoverage(paths: [link.path])

        #expect(coverage.position(ofFileURL: file.absoluteString) == .inside)
    }

    @Test("trackIDs returns the ids at a position, ascending")
    func trackIDs() {
        let coverage = RootCoverage(paths: ["/m/Music"])
        let urls: [Int64: String] = [
            3: "file:///m/Music/3.flac", 1: "file:///m/Music/1.flac",
            2: "file:///m/Other/2.flac", 4: "https://example.test/4.mp3",
        ]
        #expect(coverage.trackIDs(in: urls, at: .inside) == [1, 3])
        #expect(coverage.trackIDs(in: urls, at: .outside) == [2])
    }
}
