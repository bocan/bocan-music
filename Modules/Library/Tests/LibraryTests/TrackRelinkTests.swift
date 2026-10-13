import Foundation
import Persistence
import Testing
@testable import Library

// MARK: - Helpers

private func makeScratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bocan-647-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes `bytes` to `folder/name` with the modification time `mtime`.
private func writeFile(_ bytes: [UInt8], to folder: URL, mtime: Int64, name: String = "song.flac") throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: TimeInterval(mtime))],
        ofItemAtPath: url.path
    )
    return url
}

/// A track row as the library holds it for `file`.
private func insertTrack(
    for file: URL,
    in tracks: TrackRepository,
    mtime: Int64,
    hidden: Bool = true,
    hashed: Bool = false
) async throws -> Int64 {
    let size = try Int64(#require(file.resourceValues(forKeys: [.fileSizeKey]).fileSize))
    let id = try await tracks.insert(Track(
        fileURL: file.absoluteString,
        fileSize: size,
        fileMtime: mtime,
        fileFormat: "flac",
        duration: 180,
        title: "T",
        rating: 80,
        disabled: hidden,
        addedAt: 1,
        updatedAt: 1
    ))
    if hashed {
        try await tracks.setContentHash(trackID: id, hash: ContentHashService.sha256Hex(ofFileAt: file))
    }
    return id
}

private let bytes: [UInt8] = Array(repeating: 7, count: 4096)
private let time: Int64 = 1_700_000_000

// MARK: - TrackRelinkerTests

/// When a new file is the same file as a hidden track (#647).
@Suite("TrackRelinker")
struct TrackRelinkerTests {
    @Test("the same name, size and modification time re-links without a content hash")
    func sameNameSizeAndTime() async throws {
        let tracks = try await TrackRepository(database: Database(location: .inMemory))
        let root = try makeScratch()
        let old = try writeFile(bytes, to: root.appendingPathComponent("old"), mtime: time)
        let new = try writeFile(bytes, to: root.appendingPathComponent("new"), mtime: time)
        let id = try await insertTrack(for: old, in: tracks, mtime: time)

        let track = await TrackRelinker(trackRepo: tracks).relink(url: new, size: 4096, mtime: time)

        #expect(track?.id == id)
        #expect(track?.fileURL == new.absoluteString)
        #expect(track?.disabled == false)
        #expect(track?.rating == 80)
    }

    @Test("a copy with a new modification time re-links when its bytes match the stored hash")
    func hashDecidesWhenTheTimeDiffers() async throws {
        let tracks = try await TrackRepository(database: Database(location: .inMemory))
        let root = try makeScratch()
        let old = try writeFile(bytes, to: root.appendingPathComponent("old"), mtime: time)
        let new = try writeFile(bytes, to: root.appendingPathComponent("new"), mtime: time + 500)
        let id = try await insertTrack(for: old, in: tracks, mtime: time, hashed: true)

        let track = await TrackRelinker(trackRepo: tracks).relink(url: new, size: 4096, mtime: time + 500)

        #expect(track?.id == id)
        #expect(track?.fileMtime == time + 500, "the same bytes must not read as a changed file")
        #expect(track?.contentHash != nil)
    }

    @Test("a renamed copy with the same time re-links when its bytes match the stored hash")
    func hashDecidesWhenTheNameDiffers() async throws {
        let tracks = try await TrackRepository(database: Database(location: .inMemory))
        let root = try makeScratch()
        let old = try writeFile(bytes, to: root.appendingPathComponent("old"), mtime: time)
        let new = try writeFile(bytes, to: root.appendingPathComponent("new"), mtime: time, name: "renamed.flac")
        let id = try await insertTrack(for: old, in: tracks, mtime: time, hashed: true)

        let track = await TrackRelinker(trackRepo: tracks).relink(url: new, size: 4096, mtime: time)

        #expect(track?.id == id)
    }

    @Test("no re-link when the time differs and the hidden track has no hash yet")
    func noHashNoRelink() async throws {
        let tracks = try await TrackRepository(database: Database(location: .inMemory))
        let root = try makeScratch()
        let old = try writeFile(bytes, to: root.appendingPathComponent("old"), mtime: time)
        let new = try writeFile(bytes, to: root.appendingPathComponent("new"), mtime: time + 500)
        let id = try await insertTrack(for: old, in: tracks, mtime: time)

        let track = await TrackRelinker(trackRepo: tracks).relink(url: new, size: 4096, mtime: time + 500)

        #expect(track == nil)
        #expect(try await tracks.fetch(id: id).disabled)
    }

    @Test("no re-link for a different file of the same name and size")
    func differentBytes() async throws {
        let tracks = try await TrackRepository(database: Database(location: .inMemory))
        let root = try makeScratch()
        let old = try writeFile(bytes, to: root.appendingPathComponent("old"), mtime: time)
        var changed = bytes
        changed[100] = 9
        let new = try writeFile(changed, to: root.appendingPathComponent("new"), mtime: time + 500)
        _ = try await insertTrack(for: old, in: tracks, mtime: time, hashed: true)

        let track = await TrackRelinker(trackRepo: tracks).relink(url: new, size: 4096, mtime: time + 500)

        #expect(track == nil)
    }

    @Test("no re-link when neither the name nor the time is the same")
    func nothingInCommonButTheSize() async throws {
        let tracks = try await TrackRepository(database: Database(location: .inMemory))
        let root = try makeScratch()
        let old = try writeFile(bytes, to: root.appendingPathComponent("old"), mtime: time)
        let new = try writeFile(bytes, to: root.appendingPathComponent("new"), mtime: time + 500, name: "other.flac")
        _ = try await insertTrack(for: old, in: tracks, mtime: time, hashed: true)

        let track = await TrackRelinker(trackRepo: tracks).relink(url: new, size: 4096, mtime: time + 500)

        #expect(track == nil)
    }

    @Test("a visible track is never taken: a second copy is a second track")
    func visibleTrackIsNotACandidate() async throws {
        let tracks = try await TrackRepository(database: Database(location: .inMemory))
        let root = try makeScratch()
        let old = try writeFile(bytes, to: root.appendingPathComponent("old"), mtime: time)
        let new = try writeFile(bytes, to: root.appendingPathComponent("new"), mtime: time)
        _ = try await insertTrack(for: old, in: tracks, mtime: time, hidden: false)

        let track = await TrackRelinker(trackRepo: tracks).relink(url: new, size: 4096, mtime: time)

        #expect(track == nil)
    }

    @Test("true duplicates each go back to the copy in the matching folder, once")
    func duplicatesFollowTheirFolders() async throws {
        let tracks = try await TrackRepository(database: Database(location: .inMemory))
        let root = try makeScratch()
        let oldA = try writeFile(bytes, to: root.appendingPathComponent("old/Album A"), mtime: time)
        let oldB = try writeFile(bytes, to: root.appendingPathComponent("old/Album B"), mtime: time)
        let newA = try writeFile(bytes, to: root.appendingPathComponent("new/Album A"), mtime: time)
        let newB = try writeFile(bytes, to: root.appendingPathComponent("new/Album B"), mtime: time)
        let extra = try writeFile(bytes, to: root.appendingPathComponent("new/Album C"), mtime: time)
        let idA = try await insertTrack(for: oldA, in: tracks, mtime: time)
        let idB = try await insertTrack(for: oldB, in: tracks, mtime: time)
        let relinker = TrackRelinker(trackRepo: tracks)
        await relinker.beginScan()

        // B first: the lowest id alone would hand it A's row.
        let second = await relinker.relink(url: newB, size: 4096, mtime: time)
        let first = await relinker.relink(url: newA, size: 4096, mtime: time)
        let third = await relinker.relink(url: extra, size: 4096, mtime: time)
        await relinker.endScan()

        #expect(first?.id == idA)
        #expect(second?.id == idB)
        #expect(third == nil, "a hidden track is given to one file only")
    }

    @Test("sharedSuffix counts the trailing path components two paths share")
    func sharedSuffix() {
        #expect(TrackRelinker.sharedSuffix(["/", "new", "A", "1.flac"], ["/", "old", "A", "1.flac"]) == 2)
        #expect(TrackRelinker.sharedSuffix(["/", "new", "1.flac"], ["/", "old", "2.flac"]) == 0)
    }
}

// MARK: - MovedLibraryTests

/// The whole path: a library folder is removed, moved, and added again (#647).
@Suite("Moved library keeps its tracks")
struct MovedLibraryTests {
    private func fixtureTrack() throws -> URL {
        let library = try #require(Bundle.module.url(
            forResource: "sample-library",
            withExtension: nil,
            subdirectory: "Fixtures"
        ))
        return library.appendingPathComponent("Artist A/Album One/03 - Third Track.flac")
    }

    private func scan(_ scanner: LibraryScanner) async -> ScanProgress.Summary? {
        var summary: ScanProgress.Summary?
        for await event in await scanner.scan() {
            if case let .finished(result) = event {
                summary = result
            }
        }
        return summary
    }

    /// What `moveLibrary` saw.
    private struct Move {
        let before: Track
        let after: Track
        let summary: ScanProgress.Summary
        let tracks: TrackRepository
    }

    /// Scans a one-track library at `old`, lets `edit` change the track, then
    /// removes the folder, moves it to a new place and scans that.
    private func moveLibrary(edit: (inout Track) -> Void) async throws -> Move {
        let db = try await Database(location: .inMemory)
        let scanner = LibraryScanner(database: db)
        let tracks = TrackRepository(database: db)
        let root = try makeScratch()
        let old = root.appendingPathComponent("old drive/Music", isDirectory: true)
        try FileManager.default.createDirectory(at: old.appendingPathComponent("Album"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: self.fixtureTrack(), to: old.appendingPathComponent("Album/song.flac"))
        try await scanner.addRoot(old)
        _ = await self.scan(scanner)
        let id = try #require(try await tracks.enabledFileURLs().keys.first)
        var before = try await tracks.fetch(id: id)
        edit(&before)
        try await tracks.update(before)

        let oldRootID = try #require(try await scanner.roots().first?.id)
        try await scanner.removeRoot(id: oldRootID)
        #expect(try await tracks.fetch(id: id).disabled)
        let new = root.appendingPathComponent("new drive/Music", isDirectory: true)
        try FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old, to: new)
        try await scanner.addRoot(new)
        let summary = try #require(await self.scan(scanner))

        return try await Move(before: before, after: tracks.fetch(id: id), summary: summary, tracks: tracks)
    }

    @Test("the track keeps its row, and so its rating and play count, under the new path")
    func movedTrackKeepsItsRow() async throws {
        let moved = try await self.moveLibrary { track in
            track.rating = 100
            track.playCount = 7
            track.loved = true
        }

        #expect(moved.summary.inserted == 0)
        #expect(moved.summary.updated == 1)
        #expect(try await moved.tracks.fetchAllIncludingDisabled().count == 1, "no second row for the same file")
        #expect(!moved.after.disabled)
        #expect(moved.after.fileURL.contains("new%20drive"))
        #expect(moved.after.filePathDisplay?.contains("new drive") == true)
        #expect(moved.after.fileBookmark != nil, "a bookmark for the new place")
        #expect(moved.after.rating == 100)
        #expect(moved.after.playCount == 7)
        #expect(moved.after.loved)
        #expect(moved.after.albumID != nil, "the album was pruned with the old folder and is linked again")
    }

    @Test("a track with edited tags keeps the edits and gets an album again")
    func userEditedTrackComesBackWithAnAlbum() async throws {
        let moved = try await self.moveLibrary { track in
            track.title = "My Title"
            track.userEdited = true
        }

        #expect(!moved.after.disabled)
        #expect(moved.after.id == moved.before.id)
        #expect(moved.after.title == "My Title")
        #expect(moved.after.userEdited)
        #expect(moved.after.albumID != nil)
        #expect(moved.after.artistID != nil)
        #expect(moved.after.fileBookmark != nil)
    }
}
