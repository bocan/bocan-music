import Foundation
import Persistence
import Testing
@testable import Podcasts

// MARK: - Helpers

private let feedURL = URL(string: "https://example.com/feed.rss")!
private let subscribedAt = Date(timeIntervalSince1970: 1_700_000_000)

/// A settable clock, so a test can subscribe and then let the feed go stale.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(_ now: Date) {
        self._now = now
    }

    var now: Date {
        self.lock.withLock { self._now }
    }

    func advance(by seconds: TimeInterval) {
        self.lock.withLock { self._now += seconds }
    }
}

/// Stands in for the scheduler's sleep. Records every requested wait and
/// reports it on `sleeps`, then parks until the scheduler cancels it, so no
/// test waits on real time. `elapseNext()` lets one wait finish at once, which
/// is a timer tick.
private final class SleepProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [TimeInterval] = []
    private var toElapse = 0
    let sleeps: AsyncStream<TimeInterval>
    private let continuation: AsyncStream<TimeInterval>.Continuation

    init() {
        (self.sleeps, self.continuation) = AsyncStream.makeStream(of: TimeInterval.self)
    }

    var requests: [TimeInterval] {
        self.lock.withLock { self._requests }
    }

    func elapseNext() {
        self.lock.withLock { self.toElapse += 1 }
    }

    func sleep(_ seconds: TimeInterval) async throws {
        let elapse = self.lock.withLock {
            self._requests.append(seconds)
            guard self.toElapse > 0 else { return false }
            self.toElapse -= 1
            return true
        }
        self.continuation.yield(seconds)
        if !elapse {
            try await Task.sleep(for: .seconds(24 * 3600))
        }
    }
}

private struct Bed {
    let service: PodcastService
    let clock: TestClock
    let feedRequests: RequestRecorder
    let probe: SleepProbe
    let tempDirs: [URL]

    func scheduler(_ settings: PodcastSettings) -> FeedRefreshScheduler {
        let probe = self.probe
        return FeedRefreshScheduler(service: self.service, settings: settings) { try await probe.sleep($0) }
    }

    func cleanUp() {
        for dir in self.tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

/// An in-memory library with one subscribed show whose last refresh is two
/// hours old, so every scheduled pass finds it stale. `feedRequests` holds
/// only the requests made after the subscription.
private func makeBed(stale: Bool = true) async throws -> Bed {
    guard let fixture = Bundle.module.url(forResource: "rss-full.xml", withExtension: nil, subdirectory: "Fixtures") else {
        throw PodcastsError.parseFailed(url: feedURL, reason: "rss-full.xml fixture not found")
    }
    let rss = try Data(contentsOf: fixture)

    let db = try await Database(location: .inMemory)
    let clock = TestClock(subscribedAt)
    let feedMock = MockHTTPClient()
    let recorder = RequestRecorder()
    let counting = TestFlag()
    feedMock.handler = { request in
        if counting.isSet {
            recorder.record(request)
        }
        return try (rss, stubResponse(url: feedURL))
    }
    let artRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("FeedRefreshSchedulerTests-art-\(UUID().uuidString)", isDirectory: true)
    let downloadRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("FeedRefreshSchedulerTests-dl-\(UUID().uuidString)", isDirectory: true)
    let service = PodcastService(
        podcastRepo: PodcastRepository(database: db),
        episodeRepo: EpisodeRepository(database: db),
        stateRepo: EpisodeStateRepository(database: db),
        transcriptRepo: TranscriptRepository(database: db),
        chaptersRepo: ChaptersRepository(database: db),
        fetcher: FeedFetcher(http: feedMock),
        artwork: PodcastArtworkCache(http: MockHTTPClient(), root: artRoot),
        downloadStore: DownloadStore(root: downloadRoot),
        transcriptHTTP: MockHTTPClient()
    ) { clock.now }
    _ = try await service.subscribe(feedURL: feedURL)
    counting.set()
    if stale {
        clock.advance(by: 2 * 3600)
    }
    return Bed(
        service: service,
        clock: clock,
        feedRequests: recorder,
        probe: SleepProbe(),
        tempDirs: [artRoot, downloadRoot]
    )
}

private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        self.lock.withLock { self.value }
    }

    func set() {
        self.lock.withLock { self.value = true }
    }
}

// MARK: - Tests

/// The scheduler obeys Settings > Podcasts (#605): the interval, "Manual
/// only", and "Refresh on launch". Before the fix it always refreshed at
/// launch and then every 30 minutes, whatever was stored.
@Suite("FeedRefreshScheduler", .timeLimit(.minutes(1)))
struct FeedRefreshSchedulerTests {
    // MARK: Refresh interval

    @Test("The wait between passes is the stored interval, and follows a change")
    func intervalFollowsSettings() async throws {
        let bed = try await makeBed()
        defer { bed.cleanUp() }
        let scheduler = bed.scheduler(PodcastSettings(refreshIntervalMinutes: 15, refreshOnLaunch: false))
        var sleeps = bed.probe.sleeps.makeAsyncIterator()

        await scheduler.start()
        #expect(await sleeps.next() == 900)

        await scheduler.apply(PodcastSettings(refreshIntervalMinutes: 60, refreshOnLaunch: false))
        #expect(await sleeps.next() == 3600)

        // Changing the interval restarts the wait; it does not refresh.
        #expect(bed.feedRequests.requests.isEmpty)
        await scheduler.stop()
    }

    @Test("When the interval elapses, stale feeds are refreshed and the wait starts again")
    func tickRefreshesStaleFeeds() async throws {
        let bed = try await makeBed()
        defer { bed.cleanUp() }
        let scheduler = bed.scheduler(PodcastSettings(refreshIntervalMinutes: 30, refreshOnLaunch: false))
        var sleeps = bed.probe.sleeps.makeAsyncIterator()
        bed.probe.elapseNext()

        await scheduler.start()
        #expect(await sleeps.next() == 1800) // elapses at once: the tick
        #expect(await sleeps.next() == 1800) // the pass is done, waiting again

        #expect(bed.feedRequests.requests.count == 1)
        await scheduler.stop()
    }

    @Test("A feed refreshed within half an interval is not fetched again")
    func freshFeedIsSkipped() async throws {
        let bed = try await makeBed(stale: false)
        defer { bed.cleanUp() }
        bed.clock.advance(by: 10 * 60) // 10 minutes old, the gate for 30 minutes is 15
        let scheduler = bed.scheduler(PodcastSettings(refreshIntervalMinutes: 30, refreshOnLaunch: true))
        var sleeps = bed.probe.sleeps.makeAsyncIterator()

        await scheduler.start()
        _ = await sleeps.next()

        #expect(bed.feedRequests.requests.isEmpty)
        await scheduler.stop()
    }

    // MARK: Manual only

    @Test("Manual only never starts the timer")
    func manualOnlyNeverWaits() async throws {
        let bed = try await makeBed()
        defer { bed.cleanUp() }
        let scheduler = bed.scheduler(PodcastSettings(refreshIntervalMinutes: 0, refreshOnLaunch: false))

        await scheduler.start()
        await scheduler.loop?.value

        #expect(await scheduler.loop == nil)
        #expect(bed.probe.requests.isEmpty)
        #expect(bed.feedRequests.requests.isEmpty)
    }

    @Test("Switching to Manual only stops the running timer; switching back starts it")
    func manualOnlyStopsTheTimer() async throws {
        let bed = try await makeBed()
        defer { bed.cleanUp() }
        let scheduler = bed.scheduler(PodcastSettings(refreshIntervalMinutes: 30, refreshOnLaunch: false))
        var sleeps = bed.probe.sleeps.makeAsyncIterator()

        await scheduler.start()
        #expect(await sleeps.next() == 1800)
        let running = try #require(await scheduler.loop)

        await scheduler.apply(PodcastSettings(refreshIntervalMinutes: 0, refreshOnLaunch: false))
        await running.value

        #expect(await scheduler.loop == nil)
        #expect(bed.probe.requests == [1800])
        #expect(bed.feedRequests.requests.isEmpty)

        await scheduler.apply(PodcastSettings(refreshIntervalMinutes: 15, refreshOnLaunch: false))
        #expect(await sleeps.next() == 900)
        await scheduler.stop()
    }

    // MARK: Refresh on launch

    @Test("Refresh on launch off: start does not fetch any feed")
    func launchRefreshSkippedWhenOff() async throws {
        let bed = try await makeBed()
        defer { bed.cleanUp() }
        let scheduler = bed.scheduler(PodcastSettings(refreshIntervalMinutes: 30, refreshOnLaunch: false))
        var sleeps = bed.probe.sleeps.makeAsyncIterator()

        await scheduler.start()
        _ = await sleeps.next() // the launch work is over once the first wait begins

        #expect(bed.feedRequests.requests.isEmpty)
        await scheduler.stop()
    }

    @Test("Refresh on launch on: start fetches the stale feed before the first wait")
    func launchRefreshRunsWhenOn() async throws {
        let bed = try await makeBed()
        defer { bed.cleanUp() }
        let scheduler = bed.scheduler(PodcastSettings(refreshIntervalMinutes: 30, refreshOnLaunch: true))
        var sleeps = bed.probe.sleeps.makeAsyncIterator()

        await scheduler.start()
        _ = await sleeps.next()

        #expect(bed.feedRequests.requests.count == 1)
        await scheduler.stop()
    }

    @Test("Manual only with Refresh on launch on: one launch refresh, then no timer")
    func manualOnlyStillRefreshesOnLaunch() async throws {
        let bed = try await makeBed()
        defer { bed.cleanUp() }
        let scheduler = bed.scheduler(PodcastSettings(refreshIntervalMinutes: 0, refreshOnLaunch: true))

        await scheduler.start()
        await scheduler.loop?.value

        #expect(bed.feedRequests.requests.count == 1)
        #expect(bed.probe.requests.isEmpty)
        #expect(await scheduler.loop == nil)
    }

    @Test("start is idempotent: a second call does not refresh or wait again")
    func startIsIdempotent() async throws {
        let bed = try await makeBed()
        defer { bed.cleanUp() }
        let scheduler = bed.scheduler(PodcastSettings(refreshIntervalMinutes: 0, refreshOnLaunch: true))

        await scheduler.start()
        await scheduler.loop?.value
        bed.clock.advance(by: 3600)
        await scheduler.start()
        await scheduler.loop?.value

        #expect(bed.feedRequests.requests.count == 1)
    }
}
