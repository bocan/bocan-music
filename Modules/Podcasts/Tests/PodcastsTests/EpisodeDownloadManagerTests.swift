import Foundation
import Persistence
import Testing
@testable import Podcasts

// MARK: - Fake downloader

private final class FakeDownloader: EpisodeDownloading, @unchecked Sendable {
    final class Control: @unchecked Sendable {
        let url: URL
        let resumeData: Data?
        let onProgress: @Sendable (Int64, Int64) -> Void
        let onFinished: @Sendable (Result<URL, Error>) -> Void
        let pauseResumeData: Data?
        private let lock = NSLock()
        private var _cancelled = false
        var cancelled: Bool {
            self.lock.withLock { self._cancelled }
        }

        init(
            url: URL,
            resumeData: Data?,
            pauseResumeData: Data?,
            onProgress: @escaping @Sendable (Int64, Int64) -> Void,
            onFinished: @escaping @Sendable (Result<URL, Error>) -> Void
        ) {
            self.url = url
            self.resumeData = resumeData
            self.pauseResumeData = pauseResumeData
            self.onProgress = onProgress
            self.onFinished = onFinished
        }

        func markCancelled() {
            self.lock.withLock { self._cancelled = true }
        }
    }

    private let lock = NSLock()
    private var _controls: [Control] = []
    private let pauseResumeData: Data?

    init(pauseResumeData: Data? = Data([0xAA, 0xBB])) {
        self.pauseResumeData = pauseResumeData
    }

    var controls: [Control] {
        self.lock.withLock { self._controls }
    }

    func control(forGUIDFragment fragment: String) -> Control? {
        self.controls.first { $0.url.absoluteString.contains(fragment) }
    }

    func start(
        url: URL,
        resumeData: Data?,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onFinished: @escaping @Sendable (Result<URL, Error>) -> Void
    ) -> any EpisodeDownloadHandle {
        let control = Control(
            url: url,
            resumeData: resumeData,
            pauseResumeData: self.pauseResumeData,
            onProgress: onProgress,
            onFinished: onFinished
        )
        self.lock.withLock { self._controls.append(control) }
        return Handle(control: control)
    }

    private final class Handle: EpisodeDownloadHandle, @unchecked Sendable {
        let control: Control
        init(control: Control) {
            self.control = control
        }

        func cancel() {
            self.control.markCancelled()
        }

        func cancelProducingResumeData() async -> Data? {
            self.control.markCancelled()
            return self.control.pauseResumeData
        }
    }
}

// MARK: - Test bed

private struct DownloadBed {
    let db: Database
    let stateRepo: EpisodeStateRepository
    let episodeRepo: EpisodeRepository
    let store: DownloadStore
    let storeRoot: URL
    let fake: FakeDownloader
    let manager: EpisodeDownloadManager
    let podcastID: Int64
}

private func makeBed(
    maxConcurrent: Int = 2,
    pauseResumeData: Data? = Data([0xAA, 0xBB])
) async throws -> DownloadBed {
    let db = try await Database(location: .inMemory)
    let podcastRepo = PodcastRepository(database: db)
    let podcastID = try await podcastRepo.insert(Podcast(
        feedURL: "https://example.com/feed.rss", title: "Show", addedAt: 1_700_000_000
    ))
    let stateRepo = EpisodeStateRepository(database: db)
    let episodeRepo = EpisodeRepository(database: db)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DownloadManagerTests-\(UUID().uuidString)", isDirectory: true)
    let store = DownloadStore(root: root)
    let fake = FakeDownloader(pauseResumeData: pauseResumeData)
    let manager = EpisodeDownloadManager(
        stateRepo: stateRepo,
        episodeRepo: episodeRepo,
        store: store,
        downloader: fake,
        maxConcurrent: maxConcurrent
    )
    return DownloadBed(
        db: db, stateRepo: stateRepo, episodeRepo: episodeRepo,
        store: store, storeRoot: root, fake: fake, manager: manager, podcastID: podcastID
    )
}

@discardableResult
private func insertEpisode(
    _ bed: DownloadBed,
    guid: String,
    audioFragment: String? = nil,
    mime: String? = "audio/mpeg"
) async throws -> PodcastEpisode {
    let fragment = audioFragment ?? guid
    let episode = PodcastEpisode(
        podcastID: bed.podcastID,
        guid: guid,
        title: "Episode \(guid)",
        audioURL: "https://example.com/\(fragment).mp3",
        audioMIME: mime,
        addedAt: 1_700_000_000
    )
    _ = try await bed.episodeRepo.upsert(episode)
    return episode
}

private func makeTempFile(bytes: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("src-\(UUID().uuidString).tmp")
    try Data(repeating: 0x7, count: bytes).write(to: url)
    return url
}

/// Yields cooperatively until `condition` holds (the manager processes transfer
/// callbacks on hopped Tasks) or the yield budget is exhausted. Deterministic:
/// no wall-clock waits.
@discardableResult
private func eventually(_ maxYields: Int = 2000, _ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0 ..< maxYields {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

// MARK: - Collector

private actor ProgressCollector {
    private(set) var items: [EpisodeDownload] = []
    func add(_ item: EpisodeDownload) {
        self.items.append(item)
    }

    func forGUID(_ guid: String) -> [EpisodeDownload] {
        self.items.filter { $0.guid == guid }
    }
}

// MARK: - Tests

@Suite("EpisodeDownloadManager", .serialized)
struct EpisodeDownloadManagerTests {
    private func state(_ bed: DownloadBed, _ guid: String) async -> PodcastEpisodeState? {
        try? await bed.stateRepo.fetch(podcastID: bed.podcastID, guid: guid)
    }

    // MARK: Headline: full happy-path lifecycle

    @Test("queued -> downloading -> downloaded writes the file, path, and bytes")
    func happyPathLifecycle() async throws {
        let bed = try await makeBed()
        defer { try? FileManager.default.removeItem(at: bed.storeRoot) }
        try await insertEpisode(bed, guid: "g1")

        await bed.manager.download(podcastID: bed.podcastID, guid: "g1")

        // A control was created and state is downloading.
        let control = try #require(bed.fake.control(forGUIDFragment: "g1"))
        #expect(await self.state(bed, "g1")?.downloadState == .downloading)

        control.onProgress(512, 1024)
        let temp = try makeTempFile(bytes: 4096)
        control.onFinished(.success(temp))

        let done = await eventually { await self.state(bed, "g1")?.downloadState == .downloaded }
        #expect(done)

        let finalState = try #require(await self.state(bed, "g1"))
        #expect(finalState.downloadState == .downloaded)
        let path = try #require(finalState.downloadPath)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(finalState.downloadBytes == 4096)
        #expect(bed.store.exists(podcastID: bed.podcastID, guid: "g1", mime: "audio/mpeg"))
    }

    @Test("progress emits monotonically increasing fractions ending at 1.0")
    func progressMonotonic() async throws {
        let bed = try await makeBed()
        defer { try? FileManager.default.removeItem(at: bed.storeRoot) }
        try await insertEpisode(bed, guid: "g1")

        let collector = ProgressCollector()
        let consume = Task {
            for await event in bed.manager.progress {
                await collector.add(event)
            }
        }

        await bed.manager.download(podcastID: bed.podcastID, guid: "g1")
        let control = try #require(bed.fake.control(forGUIDFragment: "g1"))
        for written in stride(from: Int64(100), through: 1000, by: 100) {
            control.onProgress(written, 1000)
        }
        try control.onFinished(.success(makeTempFile(bytes: 1000)))

        _ = await eventually { await self.state(bed, "g1")?.downloadState == .downloaded }
        // Let the final emitted events drain to the collector.
        _ = await eventually { await collector.forGUID("g1").last?.status == .downloaded }
        consume.cancel()

        let events = await collector.forGUID("g1")
        let fractions = events.map(\.fractionComplete)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 }, "fractions must be monotonic")
        #expect(events.last?.fractionComplete == 1.0)
        #expect(events.last?.status == .downloaded)
    }

    // MARK: Pause / resume

    @Test("pause then resume continues with resume data (not a fresh download from 0)")
    func pauseResumeContinues() async throws {
        let bed = try await makeBed(pauseResumeData: Data([0xAA, 0xBB]))
        defer { try? FileManager.default.removeItem(at: bed.storeRoot) }
        try await insertEpisode(bed, guid: "g1")

        await bed.manager.download(podcastID: bed.podcastID, guid: "g1")
        let first = try #require(bed.fake.control(forGUIDFragment: "g1"))
        #expect(first.resumeData == nil, "first start is a fresh download")
        first.onProgress(500, 1000)

        await bed.manager.pause(podcastID: bed.podcastID, guid: "g1")
        await bed.manager.download(podcastID: bed.podcastID, guid: "g1")

        let resumed = await eventually { bed.fake.controls.count == 2 }
        #expect(resumed)
        let second = bed.fake.controls[1]
        #expect(second.resumeData == Data([0xAA, 0xBB]), "resume passes saved resume data, not a from-0 restart")
    }

    @Test("cancel deletes the partial file and resets state to none")
    func cancelDeletesPartial() async throws {
        let bed = try await makeBed()
        defer { try? FileManager.default.removeItem(at: bed.storeRoot) }
        try await insertEpisode(bed, guid: "g1")

        await bed.manager.download(podcastID: bed.podcastID, guid: "g1")
        _ = try #require(bed.fake.control(forGUIDFragment: "g1"))

        // Simulate a partial file already written at the computed store path.
        let partial = bed.store.fileURL(podcastID: bed.podcastID, guid: "g1", mime: "audio/mpeg")
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 9, count: 16).write(to: partial)

        await bed.manager.cancel(podcastID: bed.podcastID, guid: "g1")

        #expect(!FileManager.default.fileExists(atPath: partial.path), "partial file is deleted")
        let done = await eventually { await self.state(bed, "g1")?.downloadState == EpisodeDownloadState.none }
        #expect(done)
    }

    @Test("removeDownload deletes the completed file and resets state to none")
    func removeDownloadDeletesFile() async throws {
        let bed = try await makeBed()
        defer { try? FileManager.default.removeItem(at: bed.storeRoot) }
        try await insertEpisode(bed, guid: "g1")

        await bed.manager.download(podcastID: bed.podcastID, guid: "g1")
        let control = try #require(bed.fake.control(forGUIDFragment: "g1"))
        try control.onFinished(.success(makeTempFile(bytes: 2048)))
        _ = await eventually { await self.state(bed, "g1")?.downloadState == .downloaded }
        let path = try #require(await self.state(bed, "g1")?.downloadPath)
        #expect(FileManager.default.fileExists(atPath: path))

        await bed.manager.removeDownload(podcastID: bed.podcastID, guid: "g1")

        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(await self.state(bed, "g1")?.downloadState == EpisodeDownloadState.none)
    }

    // MARK: Concurrency cap

    @Test("concurrency cap holds: a third enqueue waits while two run")
    func concurrencyCap() async throws {
        let bed = try await makeBed(maxConcurrent: 2)
        defer { try? FileManager.default.removeItem(at: bed.storeRoot) }
        try await insertEpisode(bed, guid: "a", audioFragment: "a")
        try await insertEpisode(bed, guid: "b", audioFragment: "b")
        try await insertEpisode(bed, guid: "c", audioFragment: "c")

        await bed.manager.download(podcastID: bed.podcastID, guid: "a")
        await bed.manager.download(podcastID: bed.podcastID, guid: "b")
        await bed.manager.download(podcastID: bed.podcastID, guid: "c")

        #expect(bed.fake.controls.count == 2, "only two downloads run at once")
        #expect(await self.state(bed, "a")?.downloadState == .downloading)
        #expect(await self.state(bed, "b")?.downloadState == .downloading)
        #expect(await self.state(bed, "c")?.downloadState == .queued)

        // Finish 'a'; 'c' should take the freed slot.
        let controlA = try #require(bed.fake.control(forGUIDFragment: "a"))
        try controlA.onFinished(.success(makeTempFile(bytes: 100)))

        let started = await eventually { bed.fake.controls.count == 3 }
        #expect(started, "third download starts once a slot frees")
        #expect(await self.state(bed, "c")?.downloadState == .downloading)
    }

    // MARK: Resume interrupted

    @Test("resumeInterrupted re-queues an episode left downloading by a prior quit")
    func resumeInterruptedRequeues() async throws {
        let bed = try await makeBed()
        defer { try? FileManager.default.removeItem(at: bed.storeRoot) }
        try await insertEpisode(bed, guid: "g1")
        // Simulate an interrupted download from a previous launch.
        try await bed.stateRepo.setDownloadState(
            podcastID: bed.podcastID, guid: "g1", state: .downloading, path: nil, bytes: nil
        )

        await bed.manager.resumeInterrupted()

        let restarted = await eventually { bed.fake.controls.count == 1 }
        #expect(restarted, "interrupted download is re-enqueued and started")
        #expect(await self.state(bed, "g1")?.downloadState == .downloading)
    }

    // MARK: Idempotency

    @Test("download is idempotent for an already-downloaded episode")
    func idempotentForDownloaded() async throws {
        let bed = try await makeBed()
        defer { try? FileManager.default.removeItem(at: bed.storeRoot) }
        try await insertEpisode(bed, guid: "g1")
        let temp = try makeTempFile(bytes: 64)
        let dest = try bed.store.moveIntoPlace(from: temp, podcastID: bed.podcastID, guid: "g1", mime: "audio/mpeg")
        try await bed.stateRepo.setDownloadState(
            podcastID: bed.podcastID, guid: "g1", state: .downloaded, path: dest.path, bytes: 64
        )

        await bed.manager.download(podcastID: bed.podcastID, guid: "g1")

        #expect(bed.fake.controls.isEmpty, "no new transfer is started for an already-downloaded episode")
    }
}
