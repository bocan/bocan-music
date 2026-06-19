import Foundation
import Observability
import Persistence

/// Manages episode downloads: a bounded-concurrency queue, live progress, and
/// pause / resume / cancel / remove, keeping `podcast_episode_state` and the
/// on-disk file in sync.
///
/// State, not the file, is the source of truth for the UI badge; the manager
/// only flips a state row to `.downloaded` once the file is fully written and
/// moved into place (never a partial file). `PodcastService.audioURL` (phase
/// 21-4) prefers the downloaded file, so offline playback needs no player change.
public actor EpisodeDownloadManager {
    // MARK: - Dependencies

    private let stateRepo: EpisodeStateRepository
    private let episodeRepo: EpisodeRepository
    private let store: DownloadStore
    private let downloader: any EpisodeDownloading
    private let maxConcurrent: Int
    private let log = AppLogger.make(.podcasts)

    // MARK: - Progress stream

    /// Live progress for the UI. Emits one `EpisodeDownload` per state change or
    /// throttled progress tick.
    public nonisolated let progress: AsyncStream<EpisodeDownload>
    private let progressContinuation: AsyncStream<EpisodeDownload>.Continuation

    // MARK: - In-flight bookkeeping

    private struct Key: Hashable {
        let podcastID: Int64
        let guid: String
    }

    private struct Active {
        let handle: any EpisodeDownloadHandle
        var bytesWritten: Int64 = 0
        var totalBytes: Int64 = 0
        var lastEmittedFraction: Double = -1
    }

    /// Minimum fraction increase between emitted progress ticks. Bounds emissions
    /// to ~100 per download so the UI list never thrashes, without a wall-clock
    /// timer (which would make tests non-deterministic).
    private static let progressEmitDelta = 0.01

    private var active: [Key: Active] = [:]
    private var pending: [Key] = []
    private var paused: Set<Key> = []
    private var resumeData: [Key: Data] = [:]
    private var episodes: [Key: PodcastEpisode] = [:]

    // MARK: - Init

    public init(
        stateRepo: EpisodeStateRepository,
        episodeRepo: EpisodeRepository,
        store: DownloadStore = .init(),
        session: URLSession = .shared
    ) {
        self.init(
            stateRepo: stateRepo,
            episodeRepo: episodeRepo,
            store: store,
            downloader: URLSessionDownloader(session: session),
            maxConcurrent: 2
        )
    }

    /// Test seam: inject a fake downloader and a custom concurrency cap.
    init(
        stateRepo: EpisodeStateRepository,
        episodeRepo: EpisodeRepository,
        store: DownloadStore,
        downloader: any EpisodeDownloading,
        maxConcurrent: Int = 2
    ) {
        self.stateRepo = stateRepo
        self.episodeRepo = episodeRepo
        self.store = store
        self.downloader = downloader
        self.maxConcurrent = max(1, maxConcurrent)
        let (stream, continuation) = AsyncStream<EpisodeDownload>.makeStream(bufferingPolicy: .bufferingNewest(512))
        self.progress = stream
        self.progressContinuation = continuation
    }

    // MARK: - Public API

    /// Enqueue a download. Sets state to `queued`, then `downloading` when a slot
    /// frees. Idempotent: a no-op for an in-flight, queued, or already-downloaded
    /// episode. Resumes a paused download using its saved resume data.
    public func download(podcastID: Int64, guid: String) async {
        let key = Key(podcastID: podcastID, guid: guid)
        if self.active[key] != nil || self.pending.contains(key) { return }

        let wasPaused = self.paused.remove(key) != nil

        if !wasPaused,
           let state = try? await stateRepo.fetch(podcastID: podcastID, guid: guid),
           state.downloadState == .downloaded,
           let path = state.downloadPath,
           FileManager.default.fileExists(atPath: path) {
            return
        }

        if self.episodes[key] == nil {
            guard let episode = try? await episodeRepo.fetchByGUID(podcastID: podcastID, guid: guid) else {
                self.log.warning("download.enqueue.unknownEpisode", ["podcastID": podcastID, "guid": guid])
                return
            }
            self.episodes[key] = episode
        }

        self.pending.append(key)
        if !wasPaused { await self.persist(key, .queued, path: nil, bytes: nil) }
        self.emit(key, status: .queued, fraction: 0, written: 0, total: 0)
        await self.pumpQueue()
    }

    /// Cancel an in-flight or queued download, delete any partial file, and reset
    /// state to `none`.
    public func cancel(podcastID: Int64, guid: String) async {
        await self.tearDown(podcastID: podcastID, guid: guid)
    }

    /// Remove a completed (or in-flight) download: delete the file and reset state
    /// to `none`. `audioURL` then returns the enclosure URL again.
    public func removeDownload(podcastID: Int64, guid: String) async {
        await self.tearDown(podcastID: podcastID, guid: guid)
    }

    /// Pause an in-flight download, keeping resume data so a later `download`
    /// continues rather than restarting. Frees the slot for a queued download.
    public func pause(podcastID: Int64, guid: String) async {
        let key = Key(podcastID: podcastID, guid: guid)
        if let activeDownload = self.active.removeValue(forKey: key) {
            let data = await activeDownload.handle.cancelProducingResumeData()
            if let data {
                self.resumeData[key] = data
            } else {
                self.log.debug("download.pause.noResumeData", ["podcastID": podcastID, "guid": guid])
            }
            self.paused.insert(key)
            // State stays parked as `queued`; a later `download` re-enters the run queue.
            await self.persist(key, .queued, path: nil, bytes: nil)
            self.emit(
                key,
                status: .queued,
                fraction: max(0, activeDownload.lastEmittedFraction),
                written: activeDownload.bytesWritten,
                total: activeDownload.totalBytes
            )
            await self.pumpQueue()
        } else if let index = self.pending.firstIndex(of: key) {
            self.pending.remove(at: index)
            self.paused.insert(key)
            self.emit(key, status: .queued, fraction: 0, written: 0, total: 0)
        }
    }

    /// On launch: re-enqueue any episode left `.downloading` / `.queued` by a prior
    /// quit, using saved resume data when available (none, after a fresh launch).
    public func resumeInterrupted() async {
        let rows: [PodcastEpisodeState]
        do {
            rows = try await self.stateRepo.fetchByDownloadState([.downloading, .queued])
        } catch {
            self.log.warning("download.resumeInterrupted.fetchFailed", ["error": String(reflecting: error)])
            return
        }
        self.log.debug("download.resumeInterrupted", ["count": rows.count])
        for row in rows {
            await self.download(podcastID: row.podcastID, guid: row.guid)
        }
    }

    // MARK: - Private: queue pump

    private func pumpQueue() async {
        while self.active.count < self.maxConcurrent, !self.pending.isEmpty {
            let key = self.pending.removeFirst()
            guard let episode = self.episodes[key] else { continue }
            await self.startDownload(key: key, episode: episode)
        }
    }

    private func startDownload(key: Key, episode: PodcastEpisode) async {
        guard let url = URL(string: episode.audioURL) else {
            self.log.warning("download.start.badURL", ["url": episode.audioURL])
            await self.fail(key)
            return
        }
        let resume = self.resumeData[key]
        let handle = self.downloader.start(
            url: url,
            resumeData: resume,
            onProgress: { [weak self] written, total in
                Task { await self?.onProgress(key: key, written: written, total: total) }
            },
            onFinished: { [weak self] result in
                Task { await self?.onFinished(key: key, episode: episode, result: result) }
            }
        )
        self.active[key] = Active(handle: handle)
        await self.persist(key, .downloading, path: nil, bytes: nil)
        self.emit(key, status: .downloading, fraction: 0, written: 0, total: 0)
    }

    // MARK: - Private: transfer callbacks

    private func onProgress(key: Key, written: Int64, total: Int64) async {
        guard var activeDownload = self.active[key] else { return }
        activeDownload.bytesWritten = written
        activeDownload.totalBytes = total
        let fraction = total > 0 ? Double(written) / Double(total) : 0
        if fraction - activeDownload.lastEmittedFraction >= Self.progressEmitDelta {
            activeDownload.lastEmittedFraction = fraction
            self.active[key] = activeDownload
            self.emit(key, status: .downloading, fraction: fraction, written: written, total: total)
        } else {
            self.active[key] = activeDownload
        }
    }

    private func onFinished(key: Key, episode: PodcastEpisode, result: Result<URL, Error>) async {
        // If the key is no longer active, a cancel / pause already handled it.
        guard self.active[key] != nil else { return }
        self.active.removeValue(forKey: key)

        switch result {
        case let .success(tempURL):
            do {
                let dest = try self.store.moveIntoPlace(
                    from: tempURL,
                    podcastID: key.podcastID,
                    guid: key.guid,
                    mime: episode.audioMIME
                )
                let bytes = self.store.bytes(podcastID: key.podcastID, guid: key.guid, mime: episode.audioMIME) ?? 0
                await self.persist(key, .downloaded, path: dest.path, bytes: bytes)
                self.resumeData[key] = nil
                self.episodes[key] = nil
                self.emit(key, status: .downloaded, fraction: 1.0, written: bytes, total: bytes)
                self.log.debug("download.finished", ["podcastID": key.podcastID, "guid": key.guid, "bytes": bytes])
            } catch {
                self.log.error("download.move.failed", ["guid": key.guid, "error": String(reflecting: error)])
                await self.fail(key)
            }
        case let .failure(error):
            self.log.warning("download.failed", ["guid": key.guid, "error": String(reflecting: error)])
            await self.fail(key)
        }
        await self.pumpQueue()
    }

    private func fail(_ key: Key) async {
        self.episodes[key] = nil
        self.resumeData[key] = nil
        await self.persist(key, .failed, path: nil, bytes: nil)
        self.emit(key, status: .failed, fraction: 0, written: 0, total: 0)
    }

    // MARK: - Private: teardown

    private func tearDown(podcastID: Int64, guid: String) async {
        let key = Key(podcastID: podcastID, guid: guid)
        self.active.removeValue(forKey: key)?.handle.cancel()
        self.pending.removeAll { $0 == key }
        self.paused.remove(key)
        self.resumeData[key] = nil

        let mime = self.episodes[key]?.audioMIME
        if let state = try? await stateRepo.fetch(podcastID: podcastID, guid: guid),
           let path = state.downloadPath {
            self.store.deleteFile(atPath: path)
        } else {
            self.store.delete(podcastID: podcastID, guid: guid, mime: mime)
        }
        self.episodes[key] = nil

        await self.persist(key, .none, path: nil, bytes: nil)
        self.emit(key, status: .none, fraction: 0, written: 0, total: 0)
        await self.pumpQueue()
    }

    // MARK: - Private: state + progress helpers

    private func persist(_ key: Key, _ status: EpisodeDownloadState, path: String?, bytes: Int64?) async {
        do {
            try await self.stateRepo.setDownloadState(
                podcastID: key.podcastID,
                guid: key.guid,
                state: status,
                path: path,
                bytes: bytes
            )
        } catch {
            self.log.warning(
                "download.state.writeFailed",
                ["guid": key.guid, "status": status.rawValue, "error": String(reflecting: error)]
            )
        }
    }

    private func emit(_ key: Key, status: EpisodeDownloadState, fraction: Double, written: Int64, total: Int64) {
        self.progressContinuation.yield(EpisodeDownload(
            podcastID: key.podcastID,
            guid: key.guid,
            fractionComplete: fraction,
            bytesWritten: written,
            totalBytes: total,
            status: status
        ))
    }
}
