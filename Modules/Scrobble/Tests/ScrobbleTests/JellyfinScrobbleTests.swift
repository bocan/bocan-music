import Foundation
import Persistence
import Playback
import Testing
@testable import Scrobble

// MARK: - Stub delivery

actor StubJellyfinDelivery: JellyfinScrobbleDelivering {
    enum Failure {
        case never, refused, other
    }

    struct Stopped: Equatable {
        let serverID: UUID
        let itemID: String
        let positionTicks: Int64
    }

    private let reporting: Set<UUID>
    private let failure: Failure
    private(set) var started: [String] = []
    private(set) var stopped: [Stopped] = []

    init(reporting: Set<UUID>, failure: Failure = .never) {
        self.reporting = reporting
        self.failure = failure
    }

    func reportingServerIDs() async -> Set<UUID> {
        self.reporting
    }

    func reportStarted(serverID _: UUID, itemID: String) async throws {
        try self.failIfAsked()
        self.started.append(itemID)
    }

    func reportStopped(serverID: UUID, itemID: String, positionTicks: Int64) async throws {
        try self.failIfAsked()
        self.stopped.append(Stopped(serverID: serverID, itemID: itemID, positionTicks: positionTicks))
    }

    private func failIfAsked() throws {
        switch self.failure {
        case .never:
            return

        case .refused:
            throw ScrobbleError.invalidCredentials(provider: "jellyfin")

        case .other:
            throw URLError(.timedOut)
        }
    }
}

private func jellyfinPlay(queueID: Int64, server: UUID?, item: String?, duration: TimeInterval = 200) -> PlayEvent {
    PlayEvent(
        queueID: queueID,
        trackID: -1,
        artist: "Artist",
        title: "Song",
        duration: duration,
        playedAt: Date(),
        jellyfinServerID: server,
        jellyfinItemID: item
    )
}

// MARK: - Provider

@Suite("JellyfinScrobbleProvider (ADR-097)")
struct JellyfinScrobbleProviderTests {
    @Test("a counted play is one stop report at the full run time, in 100 ns ticks")
    func submitReportsStopAtFullRunTime() async throws {
        let server = UUID()
        let delivery = StubJellyfinDelivery(reporting: [server])
        let provider = JellyfinScrobbleProvider(delivery: delivery)

        let results = try await provider.submit([jellyfinPlay(queueID: 1, server: server, item: "i1", duration: 212.5)])

        #expect(results == [SubmissionResult(queueID: 1, outcome: .success)])
        #expect(await delivery.stopped == [.init(serverID: server, itemID: "i1", positionTicks: 2_125_000_000)])
        #expect(await delivery.started.isEmpty, "a counted play never also sends a start")
    }

    @Test("plays that are not from Jellyfin, or from a server with reports off, are ignored without a request")
    func ignoresOtherPlays() async throws {
        let on = UUID()
        let off = UUID()
        let delivery = StubJellyfinDelivery(reporting: [on])
        let provider = JellyfinScrobbleProvider(delivery: delivery)
        let local = PlayEvent(queueID: 2, trackID: 42, artist: "A", title: "T", duration: 100, playedAt: Date())
        let subsonic = PlayEvent(
            queueID: 3,
            trackID: -1,
            artist: "A",
            title: "T",
            duration: 100,
            playedAt: Date(),
            subsonicServerID: on,
            subsonicSongID: "s"
        )

        let results = try await provider.submit([local, subsonic, jellyfinPlay(queueID: 4, server: off, item: "x")])

        #expect(results.map(\.outcome) == [
            .ignored(reason: "not-jellyfin"),
            .ignored(reason: "not-jellyfin"),
            .ignored(reason: "server-scrobble-disabled"),
        ])
        #expect(await delivery.stopped.isEmpty)
    }

    @Test("a refused token is ignored as auth-failed, any other failure as submit-failed")
    func failures() async throws {
        let server = UUID()
        let refused = JellyfinScrobbleProvider(delivery: StubJellyfinDelivery(reporting: [server], failure: .refused))
        let broken = JellyfinScrobbleProvider(delivery: StubJellyfinDelivery(reporting: [server], failure: .other))

        let refusedResult = try await refused.submit([jellyfinPlay(queueID: 5, server: server, item: "x")])
        let brokenResult = try await broken.submit([jellyfinPlay(queueID: 6, server: server, item: "x")])

        #expect(refusedResult.first?.outcome == .ignored(reason: "auth-failed"))
        #expect(brokenResult.first?.outcome == .ignored(reason: "submit-failed"))
    }

    @Test("now playing sends a start for a reporting server only, and never throws")
    func nowPlaying() async throws {
        let on = UUID()
        let delivery = StubJellyfinDelivery(reporting: [on])
        let provider = JellyfinScrobbleProvider(delivery: delivery)

        try await provider.nowPlaying(jellyfinPlay(queueID: -1, server: on, item: "yes"))
        try await provider.nowPlaying(jellyfinPlay(queueID: -1, server: UUID(), item: "no"))
        try await JellyfinScrobbleProvider(delivery: StubJellyfinDelivery(reporting: [on], failure: .other))
            .nowPlaying(jellyfinPlay(queueID: -1, server: on, item: "fails quietly"))

        #expect(await delivery.started == ["yes"])
    }

    @Test("the provider is active only while some server has reports on")
    func authenticatedFollowsTheFlag() async {
        #expect(await JellyfinScrobbleProvider(delivery: StubJellyfinDelivery(reporting: [UUID()])).isAuthenticated())
        #expect(await !JellyfinScrobbleProvider(delivery: StubJellyfinDelivery(reporting: [])).isAuthenticated())
    }

    @Test("ticks round to the nearest 100 ns and never go negative")
    func ticks() {
        #expect(JellyfinScrobbleProvider.positionTicks(seconds: 1) == 10_000_000)
        #expect(JellyfinScrobbleProvider.positionTicks(seconds: 0.000_000_04) == 0)
        #expect(JellyfinScrobbleProvider.positionTicks(seconds: -3) == 0)
    }
}

// MARK: - Repository

@Suite("ScrobbleQueueRepository Jellyfin rows (ADR-097)")
struct JellyfinScrobbleQueueRepositoryTests {
    private func context(server: UUID, duration: TimeInterval = 200) -> JellyfinPlayContext {
        JellyfinPlayContext(
            serverID: server,
            itemID: "4F2A9C0D",
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: duration
        )
    }

    @Test("a Jellyfin play round-trips its identity and payload through fetchPending")
    func roundTrip() async throws {
        let repo = try await ScrobbleQueueRepository(database: Database(location: .inMemory))
        let server = UUID()
        let playedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await repo.enqueueJellyfin(
            context: self.context(server: server),
            playedAt: playedAt,
            durationPlayed: 150,
            providerIDs: ["jellyfin", "lastfm"]
        )

        let row = try #require(try await repo.fetchPending(providerID: "lastfm", now: playedAt).first)
        #expect(row.jellyfinServerID == server)
        #expect(row.jellyfinItemID == "4F2A9C0D")
        #expect(row.subsonicServerID == nil)
        #expect(row.title == "Song")
        #expect(row.artist == "Artist")
        #expect(row.album == "Album")
        #expect(row.duration == 200)
        #expect(row.durationPlayed == 150)
        #expect(row.trackID == -1)
    }

    @Test("the same play twice is one row")
    func idempotent() async throws {
        let repo = try await ScrobbleQueueRepository(database: Database(location: .inMemory))
        let server = UUID()
        let playedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let context = self.context(server: server)
        for _ in 0 ..< 2 {
            try await repo.enqueueJellyfin(context: context, playedAt: playedAt, durationPlayed: 150, providerIDs: ["jellyfin"])
        }
        #expect(try await repo.fetchPending(providerID: "jellyfin", now: playedAt).count == 1)
    }

    @Test("a song with no run time stores the time played as its length")
    func unknownLength() async throws {
        let repo = try await ScrobbleQueueRepository(database: Database(location: .inMemory))
        let playedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await repo.enqueueJellyfin(
            context: self.context(server: UUID(), duration: 0),
            playedAt: playedAt,
            durationPlayed: 95,
            providerIDs: ["jellyfin"]
        )
        let row = try #require(try await repo.fetchPending(providerID: "jellyfin", now: playedAt).first)
        #expect(row.duration == 95)
    }

    @Test("recent scrobbles keep Jellyfin rows (LEFT JOIN, payload fallback)")
    func recentKeepsJellyfinRows() async throws {
        let repo = try await ScrobbleQueueRepository(database: Database(location: .inMemory))
        let context = self.context(server: UUID())
        try await repo.enqueueJellyfin(context: context, playedAt: Date(), durationPlayed: 150, providerIDs: ["jellyfin"])
        let recent = try await repo.fetchRecent(limit: 50)
        #expect(recent.map(\.title) == ["Song"])
    }
}

// MARK: - Service

@Suite("ScrobbleService Jellyfin plays (ADR-097)", .serialized)
struct JellyfinScrobbleServiceTests {
    private func service(
        repo: ScrobbleQueueRepository,
        providers: [any ScrobbleProvider]
    ) -> ScrobbleService {
        ScrobbleService(
            providers: providers,
            repository: repo,
            reachability: StaticReachability(reachable: true),
            policy: RetryPolicy(baseDelay: 0.01, maxDelay: 0.05, maxAttempts: 2, jitter: 0)
        )
    }

    private let context = JellyfinPlayContext(serverID: UUID(), itemID: "i", title: "T", artist: "A", duration: 200)

    @Test("a counted Jellyfin play is queued for every active provider, Jellyfin and the others alike")
    func countedPlayFansOut() async throws {
        let repo = try await ScrobbleQueueRepository(database: Database(location: .inMemory))
        let jellyfin = JellyfinScrobbleProvider(delivery: StubJellyfinDelivery(reporting: [self.context.serverID]))
        let lastfm = RecordingProvider(id: "lastfm")
        let service = self.service(repo: repo, providers: [jellyfin, lastfm])

        await service.recordJellyfinPlay(context: self.context, playedAt: Date(), durationPlayed: 180)

        let jellyfinRows = try await repo.fetchPending(providerID: "jellyfin")
        let lastfmRows = try await repo.fetchPending(providerID: "lastfm")
        #expect(jellyfinRows.count == 1)
        #expect(lastfmRows.first?.jellyfinItemID == "i")
        #expect(lastfmRows.first?.title == "T")
    }

    @Test("a play below the scrobble rule is not queued")
    func shortPlayNotQueued() async throws {
        let repo = try await ScrobbleQueueRepository(database: Database(location: .inMemory))
        let service = self.service(repo: repo, providers: [RecordingProvider(id: "lastfm")])
        await service.recordJellyfinPlay(context: self.context, playedAt: Date(), durationPlayed: 10)
        #expect(try await repo.stats().pending == 0)
    }

    @Test("now playing carries the Jellyfin pair to the providers")
    func nowPlayingCarriesThePair() async throws {
        let repo = try await ScrobbleQueueRepository(database: Database(location: .inMemory))
        let provider = RecordingProvider(id: "lastfm")
        let service = self.service(repo: repo, providers: [provider])

        await service.nowPlayingJellyfin(context: self.context)

        let event = try #require(await provider.nowPlayingEvents.first)
        #expect(event.jellyfinServerID == self.context.serverID)
        #expect(event.jellyfinItemID == "i")
        #expect(event.subsonicSongID == nil)
    }

    @Test("jellyfin is a known provider id")
    func providerID() {
        #expect(ScrobbleService.providerIDs.contains("jellyfin"))
    }
}

/// A provider that is always active and records what it is sent.
private actor RecordingProvider: ScrobbleProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    private(set) var nowPlayingEvents: [PlayEvent] = []

    init(id: String) {
        self.id = id
        self.displayName = id
    }

    func isAuthenticated() async -> Bool {
        true
    }

    func nowPlaying(_ play: PlayEvent) async throws {
        self.nowPlayingEvents.append(play)
    }

    func submit(_ plays: [PlayEvent]) async throws -> [SubmissionResult] {
        plays.map { SubmissionResult(queueID: $0.queueID, outcome: .success) }
    }

    func love(track _: TrackIdentity, loved _: Bool) async throws {}
}
