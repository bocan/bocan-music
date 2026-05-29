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

    /// Regression for issue #265: the recursive walk ran in a detached task with
    /// no cancellation checks, so cancelling the owning scan didn't stop a large
    /// enumeration. `enumerate` now bails on `Task.isCancelled`; verify it
    /// enumerates nothing when invoked from an already-cancelled task (driving
    /// the producer directly, so the AsyncStream consumer's own cancellation
    /// can't mask the behaviour).
    @Test("enumeration stops cooperatively when the task is cancelled")
    func enumerationHonoursCancellation() async throws {
        let dir = try self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Root + two subdirectories, 20 audio files each = 60 total.
        for i in 0 ..< 20 {
            try self.write("root-\(i).mp3", to: dir)
        }
        for name in ["albumA", "albumB"] {
            let sub = dir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for i in 0 ..< 20 {
                try self.write("\(name)-\(i).mp3", to: sub)
            }
        }

        // Baseline: an uncancelled walk finds every file.
        let all = FileWalker._collectForTesting(dir, extensions: ["mp3"])
        #expect(all.count == 60, "baseline walk should find all 60 files, got \(all.count)")

        // Inside an already-cancelled task, enumeration must bail immediately.
        let task = Task<Int, Never> {
            // Spin until cancellation is observed so the walk runs in a known
            // cancelled context (deterministic outcome, not timing-dependent).
            while !Task.isCancelled {
                await Task.yield()
            }
            return FileWalker._collectForTesting(dir, extensions: ["mp3"]).count
        }
        task.cancel()
        let countWhenCancelled = await task.value
        #expect(countWhenCancelled == 0, "a cancelled task must enumerate nothing, got \(countWhenCancelled)")
    }
}
