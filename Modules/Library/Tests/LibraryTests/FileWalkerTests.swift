import Foundation
import Testing
@testable import Library

@Suite("FileWalker")
struct FileWalkerTests {
    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func write(_ name: String, to dir: URL) throws {
        let url = dir.appendingPathComponent(name)
        try Data("test".utf8).write(to: url)
    }

    // MARK: - Tests

    @Test("collects supported audio files")
    func collectsAudioFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try self.write("track.mp3", to: dir)
        try self.write("track.flac", to: dir)
        try self.write("track.wav", to: dir)

        var found: [URL] = []
        for await url in FileWalker.walk(dir, supportedExtensions: ["mp3", "flac", "wav"]) {
            found.append(url)
        }
        #expect(found.count == 3)
    }

    @Test("skips hidden files")
    func skipsHiddenFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try self.write("visible.mp3", to: dir)
        try self.write(".hidden.mp3", to: dir)

        var found: [URL] = []
        for await url in FileWalker.walk(dir, supportedExtensions: ["mp3"]) {
            found.append(url)
        }
        #expect(found.count == 1)
        #expect(found[0].lastPathComponent == "visible.mp3")
    }

    @Test("skips iCloud placeholder files")
    func skipsICloudPlaceholders() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try self.write("real.mp3", to: dir)
        // iCloud placeholder has the real filename wrapped inside a .icloud file
        try self.write(".real.mp3.icloud", to: dir)

        var found: [URL] = []
        for await url in FileWalker.walk(dir, supportedExtensions: ["mp3"]) {
            found.append(url)
        }
        #expect(found.count == 1)
        #expect(found[0].lastPathComponent == "real.mp3")
    }

    @Test("skips unsupported extensions")
    func skipsUnsupportedExtensions() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try self.write("photo.jpg", to: dir)
        try self.write("doc.pdf", to: dir)
        try self.write("audio.mp3", to: dir)

        var found: [URL] = []
        for await url in FileWalker.walk(dir, supportedExtensions: ["mp3"]) {
            found.append(url)
        }
        #expect(found.count == 1)
    }

    @Test("recurses into subdirectories")
    func recursesSubdirectories() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sub = dir.appendingPathComponent("album", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try self.write("track1.flac", to: dir)
        try self.write("track2.flac", to: sub)

        var found: [URL] = []
        for await url in FileWalker.walk(dir, supportedExtensions: ["flac"]) {
            found.append(url)
        }
        #expect(found.count == 2)
    }

    @Test("skips broken symlinks")
    func skipsBrokenSymlinks() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try self.write("real.mp3", to: dir)
        // Create a dangling symlink
        let link = dir.appendingPathComponent("broken.mp3")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: dir.appendingPathComponent("nonexistent.mp3")
        )

        var found: [URL] = []
        for await url in FileWalker.walk(dir, supportedExtensions: ["mp3"]) {
            found.append(url)
        }
        // Should only find the real file, not the broken symlink
        #expect(found.count == 1)
        #expect(found[0].lastPathComponent == "real.mp3")
    }

    @Test("yields a single audio file when given a file URL directly")
    func walksSingleFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("single.mp3")
        try Data("test".utf8).write(to: fileURL)

        var found: [URL] = []
        for await url in FileWalker.walk(fileURL, supportedExtensions: ["mp3"]) {
            found.append(url)
        }
        #expect(found.count == 1)
        #expect(found[0].lastPathComponent == "single.mp3")
    }

    @Test("yields nothing for unsupported single file")
    func walksSingleFileUnsupported() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("image.jpg")
        try Data("test".utf8).write(to: fileURL)

        var found: [URL] = []
        for await url in FileWalker.walk(fileURL, supportedExtensions: ["mp3"]) {
            found.append(url)
        }
        #expect(found.isEmpty)
    }
}
