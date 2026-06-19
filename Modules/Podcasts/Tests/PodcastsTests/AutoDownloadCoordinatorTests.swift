import Foundation
import Persistence
import Testing
@testable import Podcasts

// MARK: - Noop downloader (no network, never completes)

private final class NoopDownloader: EpisodeDownloading, @unchecked Sendable {
    func start(
        url _: URL,
        resumeData _: Data?,
        onProgress _: @escaping @Sendable (Int64, Int64) -> Void,
        onFinished _: @escaping @Sendable (Result<URL, Error>) -> Void
    ) -> any EpisodeDownloadHandle {
        Handle()
    }

    private final class Handle: EpisodeDownloadHandle, @unchecked Sendable {
        func cancel() {}
        func cancelProducingResumeData() async -> Data? {
            nil
        }
    }
}

// MARK: - Bed

private struct AutoBed {
    let db: Database
    let podcastRepo: PodcastRepository
    let episodeRepo: EpisodeRepository
    let stateRepo: EpisodeStateRepository
    let manager: EpisodeDownloadManager
    let storeRoot: URL
    let podcastID: Int64
}

private func makeAutoBed(autoDownload: Bool, maxConcurrent: Int = 2) async throws -> AutoBed {
    let db = try await Database(location: .inMemory)
    let podcastRepo = PodcastRepository(database: db)
    let podcastID = try await podcastRepo.insert(Podcast(
        feedURL: "https://example.com/feed.rss",
        title: "Show",
        subscribed: true,
        autoDownload: autoDownload,
        addedAt: 1_700_000_000
    ))
    let episodeRepo = EpisodeRepository(database: db)
    let stateRepo = EpisodeStateRepository(database: db)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AutoDownloadTests-\(UUID().uuidString)", isDirectory: true)
    let manager = EpisodeDownloadManager(
        stateRepo: stateRepo,
        episodeRepo: episodeRepo,
        store: DownloadStore(root: root),
        downloader: NoopDownloader(),
        maxConcurrent: maxConcurrent
    )
    return AutoBed(
        db: db, podcastRepo: podcastRepo, episodeRepo: episodeRepo, stateRepo: stateRepo,
        manager: manager, storeRoot: root, podcastID: podcastID
    )
}

/// Inserts episodes named e1...eN with strictly increasing publish dates, so
/// `fetchForPodcast` returns them newest-first (eN ... e1). Returns the guids.
@discardableResult
private func insertEpisodes(_ bed: AutoBed, count: Int) async throws -> [String] {
    var guids: [String] = []
    for index in 1 ... count {
        let guid = "e\(index)"
        guids.append(guid)
        _ = try await bed.episodeRepo.upsert(PodcastEpisode(
            podcastID: bed.podcastID,
            guid: guid,
            title: "Episode \(index)",
            audioURL: "https://example.com/\(guid).mp3",
            audioMIME: "audio/mpeg",
            publishedAt: 1_700_000_000 + Double(index) * 1000,
            addedAt: 1_700_000_000
        ))
    }
    return guids
}

private func isEnqueued(_ state: PodcastEpisodeState?) -> Bool {
    guard let state else { return false }
    return state.downloadState == .queued || state.downloadState == .downloading
}

// MARK: - Tests

@Suite("AutoDownloadCoordinator", .serialized)
struct AutoDownloadCoordinatorTests {
    private func state(_ bed: AutoBed, _ guid: String) async -> PodcastEpisodeState? {
        try? await bed.stateRepo.fetch(podcastID: bed.podcastID, guid: guid)
    }

    @Test("auto-download enqueues only the newest N new episodes for a flagged show")
    func enqueuesNewestN() async throws {
        let bed = try await makeAutoBed(autoDownload: true)
        defer { try? FileManager.default.removeItem(at: bed.storeRoot) }
        let guids = try await insertEpisodes(bed, count: 5)

        let coordinator = AutoDownloadCoordinator(
            podcastRepo: bed.podcastRepo,
            episodeRepo: bed.episodeRepo,
            stateRepo: bed.stateRepo,
            manager: bed.manager,
            newestN: 3
        )
        let outcome = RefreshOutcome(
            notModified: false, newEpisodeCount: 5, totalEpisodeCount: 5, newEpisodeGUIDs: guids
        )
        await coordinator.handleRefresh(podcastID: bed.podcastID, outcome: outcome)

        // Newest 3 (e5, e4, e3) are enqueued; e2 and e1 are not.
        #expect(await isEnqueued(self.state(bed, "e5")))
        #expect(await isEnqueued(self.state(bed, "e4")))
        #expect(await isEnqueued(self.state(bed, "e3")))
        #expect(await self.state(bed, "e2") == nil)
        #expect(await self.state(bed, "e1") == nil)
    }

    @Test("auto-download is a no-op when the show is not flagged")
    func noopWhenNotFlagged() async throws {
        let bed = try await makeAutoBed(autoDownload: false)
        defer { try? FileManager.default.removeItem(at: bed.storeRoot) }
        let guids = try await insertEpisodes(bed, count: 3)

        let coordinator = AutoDownloadCoordinator(
            podcastRepo: bed.podcastRepo, episodeRepo: bed.episodeRepo,
            stateRepo: bed.stateRepo, manager: bed.manager
        )
        let outcome = RefreshOutcome(
            notModified: false, newEpisodeCount: 3, totalEpisodeCount: 3, newEpisodeGUIDs: guids
        )
        await coordinator.handleRefresh(podcastID: bed.podcastID, outcome: outcome)

        for guid in guids {
            #expect(await self.state(bed, guid) == nil, "no downloads for a non-auto-download show")
        }
    }

    @Test("auto-download skips already-downloaded or played episodes")
    func skipsDownloadedOrPlayed() async throws {
        let bed = try await makeAutoBed(autoDownload: true)
        defer { try? FileManager.default.removeItem(at: bed.storeRoot) }
        let guids = try await insertEpisodes(bed, count: 5)

        // The newest two are already accounted for: e5 downloaded, e4 played.
        try await bed.stateRepo.setDownloadState(
            podcastID: bed.podcastID, guid: "e5", state: .downloaded, path: "/tmp/e5", bytes: 1
        )
        try await bed.stateRepo.markPlayed(podcastID: bed.podcastID, guid: "e4", now: 1_700_000_000)

        let coordinator = AutoDownloadCoordinator(
            podcastRepo: bed.podcastRepo, episodeRepo: bed.episodeRepo,
            stateRepo: bed.stateRepo, manager: bed.manager, newestN: 3
        )
        let outcome = RefreshOutcome(
            notModified: false, newEpisodeCount: 5, totalEpisodeCount: 5, newEpisodeGUIDs: guids
        )
        await coordinator.handleRefresh(podcastID: bed.podcastID, outcome: outcome)

        // e5 (downloaded) and e4 (played) are skipped; the next newest 3 are e3, e2, e1.
        #expect(await self.state(bed, "e5")?.downloadState == .downloaded)
        #expect(await self.state(bed, "e4")?.playState == .played)
        #expect(await isEnqueued(self.state(bed, "e3")))
        #expect(await isEnqueued(self.state(bed, "e2")))
        #expect(await isEnqueued(self.state(bed, "e1")))
    }

    @Test("auto-download is a no-op when the refresh found no new episodes")
    func noopWhenNoNewEpisodes() async throws {
        let bed = try await makeAutoBed(autoDownload: true)
        defer { try? FileManager.default.removeItem(at: bed.storeRoot) }
        try await insertEpisodes(bed, count: 2)

        let coordinator = AutoDownloadCoordinator(
            podcastRepo: bed.podcastRepo, episodeRepo: bed.episodeRepo,
            stateRepo: bed.stateRepo, manager: bed.manager
        )
        let outcome = RefreshOutcome(
            notModified: false, newEpisodeCount: 0, totalEpisodeCount: 2, newEpisodeGUIDs: []
        )
        await coordinator.handleRefresh(podcastID: bed.podcastID, outcome: outcome)

        #expect(await self.state(bed, "e1") == nil)
        #expect(await self.state(bed, "e2") == nil)
    }
}
