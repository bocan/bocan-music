import Foundation
import Testing
@testable import Podcasts

@Suite("DownloadStore")
struct DownloadStoreTests {
    private func makeStore() -> (store: DownloadStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (DownloadStore(root: root), root)
    }

    @Test("fileURL is deterministic and lives under the show directory")
    func fileURLDeterministic() {
        let (store, root) = self.makeStore()
        let a = store.fileURL(podcastID: 7, guid: "https://example.com/ep/1", mime: "audio/mpeg")
        let b = store.fileURL(podcastID: 7, guid: "https://example.com/ep/1", mime: "audio/mpeg")
        #expect(a == b, "same inputs map to the same path")
        #expect(a.pathExtension == "mp3")
        #expect(a.deletingLastPathComponent().lastPathComponent == "7")
        #expect(a.path.hasPrefix(root.path))
        // A guid containing slashes must not leak into the filename.
        #expect(!a.lastPathComponent.contains("/"))
    }

    @Test("extension is derived from the MIME type, defaulting to mp3")
    func extensionFromMIME() {
        #expect(DownloadStore.fileExtension(forMIME: "audio/mpeg") == "mp3")
        #expect(DownloadStore.fileExtension(forMIME: "audio/x-m4a") == "m4a")
        #expect(DownloadStore.fileExtension(forMIME: "audio/mp4") == "m4a")
        #expect(DownloadStore.fileExtension(forMIME: "audio/aac") == "aac")
        #expect(DownloadStore.fileExtension(forMIME: "audio/mpeg; charset=binary") == "mp3")
        #expect(DownloadStore.fileExtension(forMIME: nil) == "mp3")
        #expect(DownloadStore.fileExtension(forMIME: "application/octet-stream") == "mp3")
    }

    @Test("moveIntoPlace moves the temp file, replaces a stale file, and reports bytes")
    func moveIntoPlace() throws {
        let (store, root) = self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(UUID().uuidString).tmp")
        try Data(repeating: 0xAB, count: 1234).write(to: temp)

        let dest = try store.moveIntoPlace(from: temp, podcastID: 3, guid: "g1", mime: "audio/mpeg")
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(!FileManager.default.fileExists(atPath: temp.path), "temp file is consumed by the move")
        #expect(store.exists(podcastID: 3, guid: "g1", mime: "audio/mpeg"))
        #expect(store.bytes(podcastID: 3, guid: "g1", mime: "audio/mpeg") == 1234)

        // A second move replaces the stale file rather than throwing.
        let temp2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(UUID().uuidString).tmp")
        try Data(repeating: 0xCD, count: 50).write(to: temp2)
        _ = try store.moveIntoPlace(from: temp2, podcastID: 3, guid: "g1", mime: "audio/mpeg")
        #expect(store.bytes(podcastID: 3, guid: "g1", mime: "audio/mpeg") == 50)
    }

    @Test("delete removes a single file; deletePodcast removes the show directory")
    func deletion() throws {
        let (store, root) = self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        for guid in ["a", "b"] {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("dl-\(UUID().uuidString).tmp")
            try Data(repeating: 1, count: 10).write(to: temp)
            _ = try store.moveIntoPlace(from: temp, podcastID: 9, guid: guid, mime: "audio/mpeg")
        }
        #expect(store.exists(podcastID: 9, guid: "a", mime: "audio/mpeg"))

        store.delete(podcastID: 9, guid: "a", mime: "audio/mpeg")
        #expect(!store.exists(podcastID: 9, guid: "a", mime: "audio/mpeg"))
        #expect(store.exists(podcastID: 9, guid: "b", mime: "audio/mpeg"), "sibling file is untouched")

        store.deletePodcast(podcastID: 9)
        #expect(!store.exists(podcastID: 9, guid: "b", mime: "audio/mpeg"))
        let showDir = root.appendingPathComponent("9", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: showDir.path))
    }

    @Test("deleteFile removes by absolute path; missing paths are a no-op")
    func deleteByPath() throws {
        let (store, root) = self.makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(UUID().uuidString).tmp")
        try Data(repeating: 2, count: 5).write(to: temp)
        let dest = try store.moveIntoPlace(from: temp, podcastID: 1, guid: "x", mime: nil)

        store.deleteFile(atPath: dest.path)
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        // No throw / crash for a path that no longer exists.
        store.deleteFile(atPath: dest.path)
    }

    @Test("bytes returns nil for an absent file")
    func bytesAbsent() {
        let (store, _) = self.makeStore()
        #expect(store.bytes(podcastID: 42, guid: "nope", mime: "audio/mpeg") == nil)
        #expect(store.exists(podcastID: 42, guid: "nope", mime: "audio/mpeg") == false)
    }
}
