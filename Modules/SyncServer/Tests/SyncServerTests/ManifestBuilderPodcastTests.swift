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
            subscribed: true,
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

        try await states.setDownloadState(podcastID: podcastId, guid: guid, state: .downloaded, path: fileURL.path, bytes: 55_000_000)
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
        #expect(show.artworkHash == nil)

        #expect(manifest.episodes.count == 1)
        let episode = try #require(manifest.episodes.first)
        #expect(episode.id == fileURL.deletingPathExtension().lastPathComponent)
        #expect(episode.podcastId == podcastId)
        #expect(episode.guid == guid)
        #expect(episode.relPath == "Podcasts/\(podcastId)/\(fileURL.lastPathComponent)")
        #expect(episode.size == 55_000_000)
        #expect(episode.sha256.count == 64)
        #expect(episode.hasChapters)
        #expect(episode.playState == "inProgress")
        #expect(episode.playPositionMs == 1_200_000)
        #expect(episode.durationMs == 3_600_000)
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
            subscribed: true,
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
