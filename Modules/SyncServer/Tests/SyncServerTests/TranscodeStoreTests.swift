import AudioEngine
import Foundation
import Testing
@testable import SyncServer

/// The prepare-and-release workspace layout (ADR-088).
@Suite("TranscodeStore")
struct TranscodeStoreTests {
    private func makeRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcode-store-\(UUID().uuidString)")
    }

    private func removeRoot(_ root: URL) throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    @Test("artifact paths are deterministic and carry preset, id, hash prefix, and extension")
    func artifactPathsAreDeterministic() {
        let root = self.makeRoot()
        let store = TranscodeStore(root: root)
        let url = store.artifactURL(trackID: 42, sourceContentHash: "abcdef0123456789", preset: .opus128)
        #expect(url == store.artifactURL(trackID: 42, sourceContentHash: "abcdef0123456789", preset: .opus128))
        #expect(url.path.contains("opus_128"))
        #expect(url.lastPathComponent == "42-abcdef012345.opus")
        let mp3 = store.artifactURL(trackID: 42, sourceContentHash: "abcdef0123456789", preset: .mp3320)
        #expect(mp3.lastPathComponent == "42-abcdef012345.mp3")
    }

    @Test("prepare, write, exists, remove, and remove-preset round-trip")
    func lifecycleRoundTrips() throws {
        let root = self.makeRoot()
        let store = TranscodeStore(root: root)
        try store.prepareDirectory(preset: .opus128)

        let url = store.artifactURL(trackID: 7, sourceContentHash: "cafebabe0000", preset: .opus128)
        try Data("bytes".utf8).write(to: url)
        #expect(store.exists(trackID: 7, sourceContentHash: "cafebabe0000", preset: .opus128))

        store.removeArtifact(trackID: 7, sourceContentHash: "cafebabe0000", preset: .opus128)
        #expect(!store.exists(trackID: 7, sourceContentHash: "cafebabe0000", preset: .opus128))
        // Removing an absent artifact is a quiet no-op.
        store.removeArtifact(trackID: 7, sourceContentHash: "cafebabe0000", preset: .opus128)

        try Data("bytes".utf8).write(to: url)
        store.removePreset(.opus128)
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))

        try self.removeRoot(root)
    }

    @Test("the root is excluded from Time Machine after preparation")
    func rootIsBackupExcluded() throws {
        let root = self.makeRoot()
        let store = TranscodeStore(root: root)
        try store.prepareDirectory(preset: .mp3256)

        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)

        try self.removeRoot(root)
    }
}
