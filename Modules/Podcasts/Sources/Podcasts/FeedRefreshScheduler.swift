import Foundation
import Observability

/// Periodically calls `PodcastService.refreshAllStale` in the background.
///
/// The App layer starts the scheduler once after launch and feeds it the
/// Settings > Podcasts choices (`PodcastSettings`): the interval between
/// passes, "Manual only" (no periodic pass at all), and whether the launch
/// itself refreshes. `apply(_:)` follows a change while the app runs.
///
/// The per-feed staleness gate inside `refreshAllStale` follows the interval
/// (`PodcastSettings.staleAge`), so a feed is not fetched twice in quick
/// succession by a relaunch or a restarted loop.
public actor FeedRefreshScheduler {
    private let service: PodcastService
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var settings: PodcastSettings
    private var started = false
    /// The running loop; `nil` before `start`, after `stop`, and in
    /// "Manual only" once the launch pass is done.
    private(set) var loop: Task<Void, Never>?
    /// The loop's current sleep. Cancelled on its own when the interval
    /// changes, so a refresh in flight is never cut short by a settings change.
    private var wait: Task<Void, Error>?
    private let log = AppLogger.make(.podcasts)

    /// Creates a stopped scheduler; nothing runs until `start()`. `sleep`
    /// takes seconds and is injectable so tests do not wait in real time.
    public init(
        service: PodcastService,
        settings: PodcastSettings = PodcastSettings(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.service = service
        self.settings = settings
        self.sleep = sleep
    }

    /// Starts the background refresh loop. Idempotent: a second call has no
    /// effect until `stop` is called.
    ///
    /// Refreshes straight away only when "Refresh on launch" is on; otherwise
    /// the first pass comes one interval later, or never in "Manual only".
    public func start() async {
        guard !self.started else { return }
        self.started = true
        self.log.debug("podcast.scheduler.start", [
            "intervalSeconds": self.settings.refreshInterval ?? 0,
            "refreshOnLaunch": self.settings.refreshOnLaunch,
        ])
        self.spawnLoop(launch: true)
    }

    /// Takes new settings. A changed interval restarts the wait with the new
    /// value, "Manual only" ends the loop, and leaving "Manual only" starts it
    /// again; the next pass is one full interval away. "Refresh on launch" is
    /// only read by `start`.
    public func apply(_ settings: PodcastSettings) async {
        guard settings != self.settings else { return }
        let scheduleChanged = settings.refreshInterval != self.settings.refreshInterval
        self.settings = settings
        guard self.started, scheduleChanged else { return }
        self.log.debug("podcast.scheduler.intervalChanged", ["intervalSeconds": settings.refreshInterval ?? 0])
        if self.loop == nil {
            self.spawnLoop(launch: false)
        } else {
            // The loop re-reads the interval when its sleep ends early.
            self.wait?.cancel()
        }
    }

    /// Cancels the background loop. Subsequent calls to `start` restart it.
    public func stop() async {
        self.loop?.cancel()
        self.wait?.cancel()
        self.loop = nil
        self.wait = nil
        self.started = false
        self.log.debug("podcast.scheduler.stop")
    }

    /// Forces an immediate refresh of all subscribed podcasts regardless of
    /// their last-refresh timestamp. Does not affect the periodic loop timer.
    public func refreshNow() async {
        self.log.debug("podcast.scheduler.refreshNow")
        await self.service.refreshAllStale(olderThan: 0)
        await self.service.sweepTranscripts()
    }

    // MARK: - Loop

    private func spawnLoop(launch: Bool) {
        let svc = self.service
        self.loop = Task.detached(priority: .background) { [weak self, svc] in
            if launch {
                await svc.sweepTranscripts()
                if let settings = await self?.settings, settings.refreshOnLaunch {
                    await svc.refreshAllStale(olderThan: settings.staleAge)
                    await svc.sweepTranscripts()
                }
            }
            while !Task.isCancelled {
                guard let wait = await self?.nextWait() else { break }
                do {
                    try await withTaskCancellationHandler {
                        try await wait.value
                    } onCancel: {
                        wait.cancel()
                    }
                } catch {
                    // The sleep was cancelled: by `stop` (the loop condition
                    // ends it) or by a new interval (wait again with it).
                    continue
                }
                guard !Task.isCancelled, let staleAge = await self?.settings.staleAge else { break }
                await svc.refreshAllStale(olderThan: staleAge)
                await svc.sweepTranscripts()
            }
        }
    }

    /// Starts the sleep before the next pass, or returns `nil` when there is
    /// none to wait for. In "Manual only" that also retires the loop, in the
    /// same actor turn, so a later `apply` knows to start a new one.
    private func nextWait() -> Task<Void, Error>? {
        // A loop that `stop` cancelled must not touch the state of its successor.
        guard !Task.isCancelled else { return nil }
        guard let interval = self.settings.refreshInterval else {
            self.loop = nil
            self.wait = nil
            return nil
        }
        let sleep = self.sleep
        let wait = Task(priority: .background) { try await sleep(interval) }
        self.wait = wait
        return wait
    }
}
