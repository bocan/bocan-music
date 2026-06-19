import Foundation
import Observability

/// Periodically calls `PodcastService.refreshAllStale` in the background.
///
/// The App layer starts the scheduler after launch and again after
/// `NSWorkspace.didWakeNotification`. The default interval is 30 minutes;
/// the per-feed staleness gate inside `refreshAllStale` prevents any feed
/// from being fetched more than once per `olderThan` window even if
/// `start` is called multiple times.
public actor FeedRefreshScheduler {
    private let service: PodcastService
    private let interval: TimeInterval
    private var task: Task<Void, Never>?
    private let log = AppLogger.make(.podcasts)

    public init(service: PodcastService, interval: TimeInterval = 1800) {
        self.service = service
        self.interval = interval
    }

    /// Starts the background refresh loop. Idempotent: a second call while the
    /// loop is running has no effect.
    public func start() async {
        guard self.task == nil else { return }
        self.log.debug("podcast.scheduler.start", ["intervalSeconds": self.interval])
        let svc = self.service
        let ivl = self.interval
        self.task = Task.detached(priority: .background) { [svc, ivl] in
            while !Task.isCancelled {
                await svc.refreshAllStale()
                do {
                    try await Task.sleep(for: .seconds(ivl))
                } catch {
                    break // CancellationError from Task.sleep; exit cleanly.
                }
            }
        }
    }

    /// Cancels the background loop. Subsequent calls to `start` restart it.
    public func stop() async {
        self.task?.cancel()
        self.task = nil
        self.log.debug("podcast.scheduler.stop")
    }

    /// Forces an immediate refresh of all subscribed podcasts regardless of
    /// their last-refresh timestamp. Does not affect the periodic loop timer.
    public func refreshNow() async {
        self.log.debug("podcast.scheduler.refreshNow")
        await self.service.refreshAllStale(olderThan: 0)
    }
}
