import Crypto
import Foundation
import Persistence
import Podcasts
import Testing
@testable import SyncServer

@Suite("ManifestBuilder podcasts")
struct ManifestBuilderPodcastTests {
    private func makeTempRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sync-podcast-\(UUID().uuidString)")
    }

    @Test("downloaded episodes and their show appear in the manifest")
    func downloadedEpisodes() async throws {
        let database = try await Database(location: .inMemory)
        let podcasts = PodcastRepository(database: database)
        let episodes = EpisodeRepository(database: database)
        let states = EpisodeStateRepository(database: database)

        let tempRoot = self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let podcastId = try await podcasts.insert(Podcast(
            feedURL: "https://example.test/feed",
            title: "Some Show",
            author: "Someone",
            description: "<p>A show about things.</p>",
            playbackSpeed: 1.2,
            addedAt: 0
        ))
        let guid = "https://example.test/some-show/12"
        _ = try await episodes.upsert(PodcastEpisode(
            podcastID: podcastId,
            guid: guid,
            title: "Episode 12",
            descriptionHTML: "<p>Show notes.</p>",
            audioURL: "https://example.test/12.mp3",
            audioMIME: "audio/mpeg",
            duration: 3600,
            publishedAt: Date(timeIntervalSince1970: 1_717_232_400).timeIntervalSince1970,
            chaptersURL: "https://example.test/12/chapters.json",
            addedAt: 0
        ))

        // Create the downloaded file the builder will hash.
        let store = DownloadStore(root: tempRoot)
        let fileURL = store.fileURL(podcastID: podcastId, guid: guid, mime: "audio/mpeg")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("podcast-audio".utf8).write(to: fileURL)

        let episodeHash = String(repeating: "bb01", count: 16)
        try await states.setDownloadState(
            podcastID: podcastId, guid: guid, state: .downloaded, path: fileURL.path, bytes: 55_000_000, hash: episodeHash
        )
        try await states.savePosition(podcastID: podcastId, guid: guid, position: 1200, now: 0)

        let builder = ManifestBuilder(database: database, downloadRoot: tempRoot)
        let manifest = try await builder.build(
            profile: .everything(includePodcasts: true),
            serverId: "srv", serverName: "Mac", generation: 1, generatedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(manifest.podcasts.count == 1)
        let show = try #require(manifest.podcasts.first)
        #expect(show.id == podcastId)
        #expect(show.title == "Some Show")
        #expect(show.author == "Someone")
        #expect(show.descriptionHtml == "<p>A show about things.</p>")
        #expect(show.playbackSpeed == 1.2)
        // No cached artwork file, so no hash is advertised (22-10).
        #expect(show.artworkHash == nil)

        #expect(manifest.episodes.count == 1)
        let episode = try #require(manifest.episodes.first)
        #expect(episode.id == fileURL.deletingPathExtension().lastPathComponent)
        #expect(episode.podcastId == podcastId)
        #expect(episode.guid == guid)
        #expect(episode.relPath == "Podcasts/\(podcastId)/\(fileURL.lastPathComponent)")
        #expect(episode.size == 55_000_000)
        #expect(episode.sha256 == episodeHash) // the stored download hash, not re-hashed
        #expect(episode.hasChapters)
        #expect(episode.playState == "inProgress")
        #expect(episode.playPositionMs == 1_200_000)
        #expect(episode.durationMs == 3_600_000)
    }

    @Test("an episode stored before the hash migration is hashed from its file (#485)")
    func legacyEpisodeHashedFromFile() async throws {
        let database = try await Database(location: .inMemory)
        let tempRoot = self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let (podcastId, guid) = try await self.seedDownloadedEpisode(
            database: database,
            root: tempRoot,
            bytes: Data("podcast-audio".utf8),
            storedHash: nil
        )

        let manifest = try await ManifestBuilder(database: database, downloadRoot: tempRoot).build(
            profile: .everything(includePodcasts: true),
            serverId: "srv", serverName: "Mac", generation: 1, generatedAt: Date(timeIntervalSince1970: 0)
        )

        let expected = SHA256.hash(data: Data("podcast-audio".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let episode = try #require(manifest.episodes.first)
        #expect(episode.podcastId == podcastId)
        #expect(episode.guid == guid)
        #expect(episode.sha256 == expected)
    }

    @Test("an episode whose file cannot be read is left out, never advertised under a partial hash (#485)")
    func unreadableEpisodeOmitted() async throws {
        let database = try await Database(location: .inMemory)
        let tempRoot = self.makeTempRoot()
        let (podcastId, guid) = try await self.seedDownloadedEpisode(
            database: database,
            root: tempRoot,
            bytes: Data("podcast-audio".utf8),
            storedHash: nil,
            permissions: 0o000
        )
        defer {
            // Restore read access so the temporary tree can be removed.
            let fileURL = DownloadStore(root: tempRoot).fileURL(podcastID: podcastId, guid: guid, mime: "audio/mpeg")
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let manifest = try await ManifestBuilder(database: database, downloadRoot: tempRoot).build(
            profile: .everything(includePodcasts: true),
            serverId: "srv", serverName: "Mac", generation: 1, generatedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(manifest.episodes.isEmpty)
    }

    /// Inserts a show plus one downloaded episode and writes its file.
    private func seedDownloadedEpisode(
        database: Database,
        root: URL,
        bytes: Data,
        storedHash: String?,
        permissions: Int? = nil
    ) async throws -> (podcastId: Int64, guid: String) {
        let podcastId = try await PodcastRepository(database: database).insert(Podcast(
            feedURL: "https://example.test/feed",
            title: "Some Show",
            addedAt: 0
        ))
        let guid = "https://example.test/some-show/12"
        _ = try await EpisodeRepository(database: database).upsert(PodcastEpisode(
            podcastID: podcastId,
            guid: guid,
            title: "Episode 12",
            audioURL: "https://example.test/12.mp3",
            audioMIME: "audio/mpeg",
            addedAt: 0
        ))
        let fileURL = DownloadStore(root: root).fileURL(podcastID: podcastId, guid: guid, mime: "audio/mpeg")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: fileURL)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: fileURL.path)
        }
        try await EpisodeStateRepository(database: database).setDownloadState(
            podcastID: podcastId,
            guid: guid,
            state: .downloaded,
            path: fileURL.path,
            bytes: Int64(bytes.count),
            hash: storedHash
        )
        return (podcastId, guid)
    }

    @Test("a show with cached artwork advertises its SHA-256; a gone file advertises nil (22-10)")
    func artworkHashAdvertised() async throws {
        let database = try await Database(location: .inMemory)
        let podcasts = PodcastRepository(database: database)
        let episodes = EpisodeRepository(database: database)
        let states = EpisodeStateRepository(database: database)
        let tempRoot = self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let podcastId = try await podcasts.insert(Podcast(
            feedURL: "https://example.test/feed",
            title: "Show",
            addedAt: 0
        ))
        let guid = "g1"
        _ = try await episodes.upsert(PodcastEpisode(
            podcastID: podcastId, guid: guid, title: "E", audioURL: "u", audioMIME: "audio/mpeg", addedAt: 0
        ))
        let store = DownloadStore(root: tempRoot)
        let fileURL = store.fileURL(podcastID: podcastId, guid: guid, mime: "audio/mpeg")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: fileURL)
        try await states.setDownloadState(podcastID: podcastId, guid: guid, state: .downloaded, path: fileURL.path, bytes: 1)

        // The cached art file, hashed the way cache time does (22-10 step 2).
        let artBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let artURL = tempRoot.appendingPathComponent("art.png")
        try artBytes.write(to: artURL)
        let expectedHash = SHA256.hash(data: artBytes).map { String(format: "%02x", $0) }.joined()
        try await podcasts.setArtwork(id: podcastId, path: artURL.path, hash: expectedHash)

        let builder = ManifestBuilder(database: database, downloadRoot: tempRoot)
        let manifest = try await builder.build(
            profile: .everything(includePodcasts: true),
            serverId: "srv", serverName: "Mac", generation: 1, generatedAt: Date(timeIntervalSince1970: 0)
        )
        let show = try #require(manifest.podcasts.first)
        #expect(show.artworkHash == expectedHash, "the manifest must advertise the stored SHA-256 of the art bytes")

        // A since-deleted file must stop being advertised: the phone would 404
        // fetching a hash the Mac cannot resolve to bytes.
        try FileManager.default.removeItem(at: artURL)
        let rebuilt = try await builder.build(
            profile: .everything(includePodcasts: true),
            serverId: "srv", serverName: "Mac", generation: 2, generatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(try #require(rebuilt.podcasts.first).artworkHash == nil)
    }

    @Test("podcasts are omitted when the profile excludes them")
    func podcastsExcludedByProfile() async throws {
        let database = try await Database(location: .inMemory)
        let podcasts = PodcastRepository(database: database)
        let episodes = EpisodeRepository(database: database)
        let states = EpisodeStateRepository(database: database)
        let tempRoot = self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let podcastId = try await podcasts.insert(Podcast(
            feedURL: "https://example.test/feed",
            title: "Show",
            addedAt: 0
        ))
        let guid = "g1"
        _ = try await episodes.upsert(PodcastEpisode(
            podcastID: podcastId,
            guid: guid,
            title: "E",
            audioURL: "u",
            audioMIME: "audio/mpeg",
            addedAt: 0
        ))
        let store = DownloadStore(root: tempRoot)
        let fileURL = store.fileURL(podcastID: podcastId, guid: guid, mime: "audio/mpeg")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: fileURL)
        try await states.setDownloadState(podcastID: podcastId, guid: guid, state: .downloaded, path: fileURL.path, bytes: 1)

        let builder = ManifestBuilder(database: database, downloadRoot: tempRoot)
        let manifest = try await builder.build(
            profile: .everything(includePodcasts: false),
            serverId: "srv", serverName: "Mac", generation: 1, generatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(manifest.podcasts.isEmpty)
        #expect(manifest.episodes.isEmpty)
    }
}
