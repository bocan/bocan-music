import Foundation
import Metadata
import Testing
@testable import Library

@Suite("BackupRing")
struct BackupRingTests {
    private func makeRing(capacity: Int = 5) throws -> (BackupRing, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupRingTests-\(UUID().uuidString)")
        let ring = try BackupRing(directory: dir, capacity: capacity)
        return (ring, dir)
    }

    @Test func saveAndLoad() async throws {
        let (ring, dir) = try makeRing()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = TagsSnapshot(from: TrackTags(title: "Hello", artist: "World"))
        let editID = try await ring.save(fileURL: "file:///test.mp3", tags: snapshot)

        let loaded = try await ring.load(editID: editID)
        #expect(loaded?.editID == editID)
        #expect(loaded?.originalTags.title == "Hello")
        #expect(loaded?.originalTags.artist == "World")
    }

    @Test func loadNonExistentReturnsNil() async throws {
        let (ring, dir) = try makeRing()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await ring.load(editID: "nonexistent-uuid")
        #expect(result == nil)
    }

    @Test func evictsOldestWhenFull() async throws {
        let (ring, dir) = try makeRing(capacity: 3)
        defer { try? FileManager.default.removeItem(at: dir) }

        var ids: [String] = []
        for i in 0 ..< 4 {
            let snap = TagsSnapshot(from: TrackTags(title: "Track \(i)"))
            let id = try await ring.save(fileURL: "file:///t\(i).mp3", tags: snap)
            ids.append(id)
        }

        // First entry should have been evicted
        let first = try await ring.load(editID: ids[0])
        #expect(first == nil)

        // Others should still be present
        let last = try await ring.load(editID: ids[3])
        #expect(last != nil)
    }

    @Test func delete() async throws {
        let (ring, dir) = try makeRing()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snap = TagsSnapshot(from: TrackTags(title: "Test"))
        let id = try await ring.save(fileURL: "file:///x.mp3", tags: snap)
        await ring.delete(editID: id)

        let loaded = try await ring.load(editID: id)
        #expect(loaded == nil)
    }

    @Test func lastEntryForFileURL() async throws {
        let (ring, dir) = try makeRing()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snap1 = TagsSnapshot(from: TrackTags(title: "v1"))
        let snap2 = TagsSnapshot(from: TrackTags(title: "v2"))
        _ = try await ring.save(fileURL: "file:///track.mp3", tags: snap1)
        _ = try await ring.save(fileURL: "file:///track.mp3", tags: snap2)

        let last = try await ring.lastEntry(forFileURL: "file:///track.mp3")
        #expect(last?.originalTags.title == "v2")
    }

    // MARK: - TagsSnapshot round-trip

    @Test func snapshotRoundTrip() {
        let tags = TrackTags(
            title: "Trip", artist: "Artist", albumArtist: "Album Artist",
            album: "Album", genre: "Rock", composer: "Bach",
            year: 2001, trackNumber: 3, discNumber: 1, bpm: 120,
            replayGain: ReplayGain(trackGain: -3.5, trackPeak: 0.99)
        )
        let snap = TagsSnapshot(from: tags)
        let restored = snap.toTrackTags()

        #expect(restored.title == "Trip")
        #expect(restored.artist == "Artist")
        #expect(restored.year == 2001)
        #expect(restored.bpm == 120)
        #expect(restored.replayGain.trackGain == -3.5)
    }
}
