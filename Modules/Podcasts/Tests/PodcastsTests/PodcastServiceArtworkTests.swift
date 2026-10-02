import CryptoKit
import Foundation
import Persistence
import Testing
@testable import Podcasts

// MARK: - Helpers

/// Polls the podcast row until `artwork_path` is non-nil (subscribe caches art on
/// a detached task), up to ~3 s. Returns the path, or nil on timeout.
private func pollArtworkPath(repo: PodcastRepository, id: Int64) async throws -> String? {
    for _ in 0 ..< 150 {
        if let path = try await repo.fetch(id: id).artworkPath {
            return path
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    return nil
}

/// Polls until `path` exists on disk, up to ~3 s. Returns the final existence.
private func pollFileExists(_ path: String) async throws -> Bool {
    for _ in 0 ..< 150 {
        if FileManager.default.fileExists(atPath: path) {
            return true
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    return FileManager.default.fileExists(atPath: path)
}

// MARK: - Tests

@Suite("PodcastService - artwork and unsubscribe", .serialized)
struct PodcastServiceArtworkTests {
    // MARK: episode artwork (#410)

    @Test("episode art is cached on demand, recorded on the row, and survives a refresh")
    func episodeArtworkCachedOnDemand() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        bed.artMock.handler = { request in
            try (Data([0xFF, 0xD8, 0xFF, 0xE0]), stubResponse(url: request.url ?? testFeedURL))
        }
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)
        let episodes = EpisodeRepository(database: bed.db)
        let before = try #require(try await episodes.fetchByGUID(podcastID: podcastID, guid: ep1GUID))
        #expect(before.artworkURL == "https://example.com/ep1-art.jpg")
        #expect(before.artworkPath == nil)

        let path = try #require(await bed.service.cacheEpisodeArtworkIfNeeded(podcastID: podcastID, guid: ep1GUID))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try await episodes.fetchByGUID(podcastID: podcastID, guid: ep1GUID)?.artworkPath == path)

        // Second call is a cache hit; a refresh does not wipe the path.
        #expect(await bed.service.cacheEpisodeArtworkIfNeeded(podcastID: podcastID, guid: ep1GUID) == path)
        _ = try await bed.service.refresh(podcastID: podcastID)
        #expect(try await episodes.fetchByGUID(podcastID: podcastID, guid: ep1GUID)?.artworkPath == path)
    }

    // MARK: unsubscribe

    @Test("unsubscribe removes the podcast row and evicts the artwork directory")
    func unsubscribeRemovesRowAndEvicts() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        // Artwork mock returns minimal image bytes.
        let artBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        bed.artMock.handler = { _ in
            try (artBytes, stubResponse("https://example.com/artwork.jpg"))
        }
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }

        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        // Manually cache artwork so we have a directory to evict.
        let artURL = try #require(URL(string: "https://example.com/artwork.jpg"))
        let repo = PodcastRepository(database: bed.db)
        _ = await bed.artCache.cachePodcastArt(podcastID: podcastID, url: artURL, repo: repo)
        let artDir = bed.artTempDir.appendingPathComponent("\(podcastID)")
        #expect(FileManager.default.fileExists(atPath: artDir.path))

        // Write a downloaded episode file so unsubscribe must delete its directory.
        let dlTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(UUID().uuidString).tmp")
        try Data("audio".utf8).write(to: dlTemp)
        _ = try bed.downloadStore.moveIntoPlace(
            from: dlTemp, podcastID: podcastID, guid: ep1GUID, mime: "audio/mpeg"
        )
        let dlDir = bed.downloadRoot.appendingPathComponent("\(podcastID)")
        #expect(FileManager.default.fileExists(atPath: dlDir.path))

        try await bed.service.unsubscribe(podcastID: podcastID)

        // Row must be gone.
        do {
            _ = try await repo.fetch(id: podcastID)
            Issue.record("Expected podcast row to be deleted after unsubscribe")
        } catch {
            // Expected: notFound.
        }

        // Artwork directory and download directory must both be evicted.
        #expect(!FileManager.default.fileExists(atPath: artDir.path))
        #expect(!FileManager.default.fileExists(atPath: dlDir.path), "unsubscribe deletes the show's downloads")
    }

    // MARK: artwork cache

    @Test("artwork cache writes a file; second call does not re-download")
    func artworkCacheDeduplicatesDownloads() async throws {
        let bed = try await makePodcastServiceBed()

        // Set up an in-memory database with one podcast row.
        let db = bed.db
        let repo = PodcastRepository(database: db)
        let testPodcast = Podcast(
            feedURL: "https://example.com/feed.rss",
            title: "Test",
            explicit: false,
            addedAt: fixedNow.timeIntervalSince1970
        )
        let podcastID = try await repo.insert(testPodcast)

        let artBytes = Data([0x89, 0x50, 0x4E, 0x47])
        var downloadCount = 0
        bed.artMock.handler = { _ in
            downloadCount += 1
            return try (artBytes, stubResponse("https://cdn.example.com/art.png"))
        }

        let artURL = try #require(URL(string: "https://cdn.example.com/art.png"))

        // First call should download and write.
        let path1 = await bed.artCache.cachePodcastArt(podcastID: podcastID, url: artURL, repo: repo)
        #expect(path1 != nil)
        #expect(try FileManager.default.fileExists(atPath: #require(path1)))

        // Second call should skip the download.
        let path2 = await bed.artCache.cachePodcastArt(podcastID: podcastID, url: artURL, repo: repo)
        #expect(path2 == path1)
        #expect(downloadCount == 1)

        // Path must be written into the podcasts row.
        let fetched = try await repo.fetch(id: podcastID)
        #expect(fetched.artworkPath == path1)

        // Cleanup.
        try? FileManager.default.removeItem(at: bed.artTempDir)
    }

    @Test("refresh re-caches cover art when the cached file is missing")
    func refreshSelfHealsMissingArtwork() async throws {
        let bed = try await makePodcastServiceBed()
        let rssData = try fixtureData(named: "rss-full.xml")
        let artBytes = Data([0x89, 0x50, 0x4E, 0x47])
        bed.artMock.handler = { _ in
            try (artBytes, stubResponse("https://example.com/artwork.jpg"))
        }
        bed.feedMock.handler = { _ in
            try (rssData, stubResponse(url: testFeedURL))
        }
        let podcastID = try await bed.service.subscribe(feedURL: testFeedURL)

        // subscribe caches art on a detached task; wait for the file + path to land.
        let repo = PodcastRepository(database: bed.db)
        let cachedPath = try #require(await pollArtworkPath(repo: repo, id: podcastID))
        #expect(FileManager.default.fileExists(atPath: cachedPath))

        // Simulate the overnight wipe: delete the cached file (the row path stays).
        try FileManager.default.removeItem(atPath: cachedPath)
        #expect(!FileManager.default.fileExists(atPath: cachedPath))

        // A refresh must re-download the missing art and preserve the path.
        _ = try await bed.service.refresh(podcastID: podcastID)
        #expect(try await pollFileExists(cachedPath), "missing cover art should self-heal on refresh")
        let healed = try await repo.fetch(id: podcastID)
        #expect(healed.artworkPath == cachedPath)

        try? FileManager.default.removeItem(at: bed.artTempDir)
    }

    @Test("cachePodcastArt stores the file's SHA-256 alongside the path (22-10)")
    func artworkCacheStoresHash() async throws {
        let bed = try await makePodcastServiceBed()
        let repo = PodcastRepository(database: bed.db)
        let podcastID = try await repo.insert(Podcast(
            feedURL: "https://example.com/feed.rss", title: "T", addedAt: 0
        ))

        let artBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let expectedHash = SHA256.hash(data: artBytes).map { String(format: "%02x", $0) }.joined()
        bed.artMock.handler = { _ in
            try (artBytes, stubResponse("https://cdn.example.com/art.png"))
        }

        let artURL = try #require(URL(string: "https://cdn.example.com/art.png"))
        _ = await bed.artCache.cachePodcastArt(podcastID: podcastID, url: artURL, repo: repo)

        let fetched = try await repo.fetch(id: podcastID)
        #expect(fetched.artworkHash == expectedHash, "stored hash must be the SHA-256 of the file bytes")

        // A pre-M033 row (path set, hash null) heals through the exists
        // short-circuit without re-downloading.
        try await repo.setArtwork(id: podcastID, path: fetched.artworkPath, hash: nil)
        var downloads = 0
        bed.artMock.handler = { _ in
            downloads += 1
            return try (artBytes, stubResponse("https://cdn.example.com/art.png"))
        }
        _ = await bed.artCache.cachePodcastArt(podcastID: podcastID, url: artURL, repo: repo)
        let healed = try await repo.fetch(id: podcastID)
        #expect(healed.artworkHash == expectedHash)
        #expect(downloads == 0, "healing a missing hash must not re-download the file")

        try? FileManager.default.removeItem(at: bed.artTempDir)
    }

    @Test("backfillArtworkHashes hashes cached art, skips missing files, and de-dupes identical bytes")
    func backfillArtworkHashes() async throws {
        let bed = try await makePodcastServiceBed()
        let repo = PodcastRepository(database: bed.db)
        let dir = bed.artTempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two shows share byte-identical art; a third points at a gone file.
        let artBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let expectedHash = SHA256.hash(data: artBytes).map { String(format: "%02x", $0) }.joined()
        let fileA = dir.appendingPathComponent("a.jpg")
        let fileB = dir.appendingPathComponent("b.jpg")
        try artBytes.write(to: fileA)
        try artBytes.write(to: fileB)

        let idA = try await repo.insert(Podcast(feedURL: "https://a.test/f", title: "A", addedAt: 0))
        let idB = try await repo.insert(Podcast(feedURL: "https://b.test/f", title: "B", addedAt: 0))
        let idGone = try await repo.insert(Podcast(feedURL: "https://c.test/f", title: "C", addedAt: 0))
        try await repo.setArtwork(id: idA, path: fileA.path, hash: nil)
        try await repo.setArtwork(id: idB, path: fileB.path, hash: nil)
        try await repo.setArtwork(id: idGone, path: dir.appendingPathComponent("gone.jpg").path, hash: nil)

        await bed.artCache.backfillArtworkHashes(repo: repo)

        let hashA = try await repo.fetch(id: idA).artworkHash
        let hashB = try await repo.fetch(id: idB).artworkHash
        #expect(hashA == expectedHash)
        #expect(hashB == expectedHash, "byte-identical art must advertise the same hash")
        #expect(try await repo.fetch(id: idGone).artworkHash == nil, "a missing file must stay unhashed")
    }

    @Test("artwork cache rejects art larger than its byte cap, accepts within it")
    func artworkCacheHonoursByteCap() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("artcap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mock = MockHTTPClient()
        let cache = PodcastArtworkCache(http: mock, root: tempRoot, maxBytes: 8)
        let url = try #require(URL(string: "https://cdn.example.com/big.png"))

        let db = try await Database(location: .inMemory)
        let podcastRepo = PodcastRepository(database: db)

        // 9 bytes > cap of 8: rejected, no file written.
        mock.handler = { _ in
            try (Data(count: 9), stubResponse(url: url))
        }
        let id = try await podcastRepo.insert(Podcast(
            feedURL: "https://example.com/feed.rss", title: "T", addedAt: 0
        ))
        let tooBig = await cache.cachePodcastArt(podcastID: id, url: url, repo: podcastRepo)
        #expect(tooBig == nil, "art over the cap must be rejected")

        // 8 bytes == cap: accepted and written.
        mock.handler = { _ in
            try (Data(count: 8), stubResponse(url: url))
        }
        let okPath = await cache.cachePodcastArt(podcastID: id, url: url, repo: podcastRepo)
        #expect(okPath != nil, "art within the cap must be accepted")
    }
}
