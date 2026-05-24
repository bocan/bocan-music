import Foundation
import Persistence
import Testing
@testable import Playback

// MARK: - PlayableSourceTests

@Suite("PlayableSource")
struct PlayableSourceTests {
    // MARK: - Equality + helpers

    @Test("isRemote is true only for .subsonic")
    func isRemoteDiscrimination() {
        #expect(PlayableSource.localBookmark(Data()).isRemote == false)
        #expect(PlayableSource.localBookmark(Data([0x01, 0x02])).isRemote == false)
        #expect(PlayableSource.subsonic(serverID: UUID(), songID: "tr-1").isRemote)
    }

    @Test("subsonicServerID/SongID surface only on .subsonic")
    func subsonicAccessors() {
        let id = UUID()
        let remote = PlayableSource.subsonic(serverID: id, songID: "tr-42")
        #expect(remote.subsonicServerID == id)
        #expect(remote.subsonicSongID == "tr-42")
        let local = PlayableSource.localBookmark(Data([0xAA]))
        #expect(local.subsonicServerID == nil)
        #expect(local.subsonicSongID == nil)
    }

    // MARK: - Codable round-trip

    @Test("Codable round-trip preserves .subsonic identity")
    func codableRoundTripSubsonic() throws {
        let id = UUID()
        let value = PlayableSource.subsonic(serverID: id, songID: "tr-99")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(PlayableSource.self, from: data)
        #expect(decoded == value)
    }

    @Test("Codable round-trip preserves .localBookmark data")
    func codableRoundTripLocal() throws {
        let bytes = Data([0x01, 0x02, 0x03])
        let value = PlayableSource.localBookmark(bytes)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(PlayableSource.self, from: data)
        #expect(decoded == value)
    }

    @Test("Codable accepts .localBookmark with missing bookmark key")
    func codableLocalMissingBookmark() throws {
        // Minimal legacy-style JSON: only the discriminator. Should decode
        // to an empty-data local bookmark and fall back to fileURL at play time.
        let json = "{\"kind\":\"localBookmark\"}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PlayableSource.self, from: json)
        #expect(decoded == .localBookmark(Data()))
    }
}

// MARK: - QueueItemPlayableSourceTests

@Suite("QueueItem playableSource defaulting")
struct QueueItemPlayableSourceTests {
    private func makeFormat() -> AudioSourceFormat {
        AudioSourceFormat(
            sampleRate: 44100, bitDepth: 16, channelCount: 2,
            isInterleaved: false, codec: "flac"
        )
    }

    @Test("default playableSource is empty localBookmark when bookmark is nil")
    func defaultLocalEmpty() {
        let item = QueueItem(
            trackID: 1, bookmark: nil,
            fileURL: "/tmp/a.flac", duration: 1,
            sourceFormat: self.makeFormat()
        )
        #expect(item.playableSource == .localBookmark(Data()))
        #expect(item.playableSource.isRemote == false)
    }

    @Test("default playableSource carries bookmark data when present")
    func defaultLocalWithBookmark() {
        let bytes = Data([0xFE, 0xED])
        let item = QueueItem(
            trackID: 2, bookmark: BookmarkBlob(data: bytes),
            fileURL: "/tmp/b.flac", duration: 1,
            sourceFormat: self.makeFormat()
        )
        #expect(item.playableSource == .localBookmark(bytes))
    }

    @Test("explicit subsonic source overrides bookmark default")
    func explicitSubsonic() {
        let server = UUID()
        let item = QueueItem(
            trackID: 3, bookmark: nil,
            fileURL: "", duration: 0,
            sourceFormat: self.makeFormat(),
            playableSource: .subsonic(serverID: server, songID: "song-1")
        )
        #expect(item.playableSource.isRemote)
        #expect(item.playableSource.subsonicServerID == server)
        #expect(item.playableSource.subsonicSongID == "song-1")
    }
}

// MARK: - QueuePersistenceMigrationTests

@Suite("QueuePersistence v1→v2 migration")
struct QueuePersistenceMigrationTests {
    private func makeFormat() -> AudioSourceFormat {
        AudioSourceFormat(
            sampleRate: 44100, bitDepth: 16, channelCount: 2,
            isInterleaved: false, codec: "flac"
        )
    }

    private func makeItem(
        trackID: Int64,
        source: PlayableSource = .localBookmark(Data())
    ) -> QueueItem {
        QueueItem(
            trackID: trackID, bookmark: nil,
            fileURL: "/tmp/\(trackID).flac", duration: 60,
            sourceFormat: self.makeFormat(),
            playableSource: source
        )
    }

    @Test("v2 round-trip preserves a mix of local and subsonic sources")
    func roundTripV2() async throws {
        let db = try await Database(location: .inMemory)
        let persistence = QueuePersistence(database: db)

        let serverID = UUID()
        let items: [QueueItem] = [
            self.makeItem(trackID: 1),
            self.makeItem(trackID: 2, source: .subsonic(serverID: serverID, songID: "alpha")),
            self.makeItem(trackID: 3, source: .subsonic(serverID: serverID, songID: "beta")),
        ]

        await persistence.scheduleSave(
            items: items, currentIndex: 1,
            repeatMode: .all, shuffleState: .off
        )
        // Wait past the 2 s debounce.
        try await Task.sleep(nanoseconds: 2_300_000_000)

        let restored = await persistence.restore()
        let restoredItems = try #require(restored?.items)
        #expect(restoredItems.count == 3)
        #expect(restoredItems[0].playableSource == .localBookmark(Data()))
        #expect(restoredItems[1].playableSource == .subsonic(serverID: serverID, songID: "alpha"))
        #expect(restoredItems[2].playableSource == .subsonic(serverID: serverID, songID: "beta"))
        #expect(restored?.currentIndex == 1)
        #expect(restored?.repeatMode == .all)
    }

    @Test("legacy v1 blob migrates to v2 and clears v1 key")
    func migrateV1ToV2() async throws {
        let db = try await Database(location: .inMemory)
        let repo = SettingsRepository(database: db)

        // Construct a v1 payload by hand: same fields as PersistedQueueItemV2
        // minus playableSource. Encoded directly via Codable.
        struct LegacyItem: Codable {
            let id: UUID
            let trackID: Int64
            let fileURL: String
            let duration: TimeInterval
            let sourceFormat: AudioSourceFormat
            let title: String?
            let artistName: String?
            let genre: String?
            let rating: Int
            let loved: Bool
            let playCount: Int
            let excludedFromShuffle: Bool
            let lastPlayedAt: Int64?
            let albumID: Int64?
            let artistID: Int64?
        }
        struct LegacyPayload: Codable {
            var items: [LegacyItem]
            var currentIndex: Int?
            var repeatMode: RepeatMode
            var shuffleState: ShuffleState
        }

        let fmt = self.makeFormat()
        let legacy = LegacyPayload(
            items: [
                LegacyItem(
                    id: UUID(), trackID: 7, fileURL: "/tmp/7.flac",
                    duration: 120, sourceFormat: fmt,
                    title: "Seven", artistName: "Artist", genre: nil,
                    rating: 0, loved: false, playCount: 0,
                    excludedFromShuffle: false, lastPlayedAt: nil,
                    albumID: nil, artistID: nil
                ),
            ],
            currentIndex: 0,
            repeatMode: .off,
            shuffleState: .off
        )
        try await repo.set(legacy, for: QueuePersistence.settingsKeyV1)

        let persistence = QueuePersistence(database: db)
        let restored = await persistence.restore()
        let items = try #require(restored?.items)
        #expect(items.count == 1)
        #expect(items[0].trackID == 7)
        #expect(items[0].playableSource == .localBookmark(Data()))

        // The migration save runs through the 2 s debounced path; wait for it.
        try await Task.sleep(nanoseconds: 2_300_000_000)

        // V1 key is gone, V2 key is populated.
        let v1Probe: Data? = try await repo.get(Data.self, for: QueuePersistence.settingsKeyV1)
        #expect(v1Probe == nil)

        // Second restore reads from V2 directly.
        let secondRestore = await persistence.restore()
        #expect(secondRestore?.items.first?.playableSource == .localBookmark(Data()))
    }
}
