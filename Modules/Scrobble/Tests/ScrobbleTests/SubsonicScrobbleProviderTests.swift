import Foundation
import Testing
@testable import Scrobble

@Suite("SubsonicScrobbleProvider")
struct SubsonicScrobbleProviderTests {
    @Test("submits Subsonic events to enabled servers")
    func submitEnabledServer() async throws {
        let server = UUID()
        let delivery = StubSubsonicDelivery(enabled: [server])
        let provider = SubsonicScrobbleProvider(delivery: delivery)
        let event = self.makePlay(queueID: 1, server: server, song: "song-1")

        let results = try await provider.submit([event])

        #expect(results == [SubmissionResult(queueID: 1, outcome: .success)])
        let calls = await delivery.scrobbleCalls
        #expect(calls.count == 1)
        #expect(calls[0].serverID == server)
        #expect(calls[0].songID == "song-1")
        #expect(calls[0].submission == true)
    }

    @Test("ignores events whose server has scrobble disabled")
    func ignoresDisabledServer() async throws {
        let enabled = UUID()
        let disabled = UUID()
        let delivery = StubSubsonicDelivery(enabled: [enabled])
        let provider = SubsonicScrobbleProvider(delivery: delivery)
        let event = self.makePlay(queueID: 7, server: disabled, song: "x")

        let results = try await provider.submit([event])

        #expect(results.first?.outcome == .ignored(reason: "server-scrobble-disabled"))
        let calls = await delivery.scrobbleCalls
        #expect(calls.isEmpty)
    }

    @Test("ignores non-Subsonic events without contacting any server")
    func ignoresLocalPlays() async throws {
        let delivery = StubSubsonicDelivery(enabled: [UUID()])
        let provider = SubsonicScrobbleProvider(delivery: delivery)
        let event = PlayEvent(
            queueID: 9, trackID: 42,
            artist: "A", title: "T",
            duration: 100, playedAt: Date()
        )

        let results = try await provider.submit([event])

        #expect(results.first?.outcome == .ignored(reason: "not-subsonic"))
        let calls = await delivery.scrobbleCalls
        #expect(calls.isEmpty)
    }

    @Test("submit failure becomes ignored(submit-failed) and does not throw")
    func submitFailureSwallowed() async throws {
        let server = UUID()
        let delivery = StubSubsonicDelivery(enabled: [server], shouldThrow: true)
        let provider = SubsonicScrobbleProvider(delivery: delivery)
        let event = self.makePlay(queueID: 3, server: server, song: "abc")

        let results = try await provider.submit([event])

        #expect(results.first?.outcome == .ignored(reason: "submit-failed"))
    }

    @Test("nowPlaying submits with submission=false for enabled servers only")
    func nowPlayingRoutesToEnabledServers() async throws {
        let enabled = UUID()
        let disabled = UUID()
        let delivery = StubSubsonicDelivery(enabled: [enabled])
        let provider = SubsonicScrobbleProvider(delivery: delivery)

        try await provider.nowPlaying(self.makePlay(queueID: -1, server: enabled, song: "ok"))
        try await provider.nowPlaying(self.makePlay(queueID: -1, server: disabled, song: "no"))

        let calls = await delivery.scrobbleCalls
        #expect(calls.count == 1)
        #expect(calls[0].submission == false)
        #expect(calls[0].serverID == enabled)
    }

    @Test("isAuthenticated reflects whether any server has scrobble enabled")
    func isAuthenticatedTracksEnabledSet() async {
        let server = UUID()
        let on = SubsonicScrobbleProvider(delivery: StubSubsonicDelivery(enabled: [server]))
        let off = SubsonicScrobbleProvider(delivery: StubSubsonicDelivery(enabled: []))
        #expect(await on.isAuthenticated() == true)
        #expect(await off.isAuthenticated() == false)
    }

    @Test("love is a no-op (handled by SubsonicAnnotations)")
    func loveIsNoop() async throws {
        let delivery = StubSubsonicDelivery(enabled: [UUID()])
        let provider = SubsonicScrobbleProvider(delivery: delivery)
        try await provider.love(track: TrackIdentity(artist: "A", title: "T"), loved: true)
        let calls = await delivery.scrobbleCalls
        #expect(calls.isEmpty)
    }

    // MARK: helpers

    private func makePlay(queueID: Int64, server: UUID, song: String) -> PlayEvent {
        PlayEvent(
            queueID: queueID, trackID: -1,
            artist: "Artist", title: "Title",
            duration: 240, playedAt: Date(),
            subsonicServerID: server, subsonicSongID: song
        )
    }
}

// MARK: - StubSubsonicDelivery

actor StubSubsonicDelivery: SubsonicScrobbleDelivering {
    struct Call: Equatable {
        let serverID: UUID
        let songID: String
        let submission: Bool
    }

    private let enabled: Set<UUID>
    private let shouldThrow: Bool
    private(set) var scrobbleCalls: [Call] = []

    init(enabled: Set<UUID>, shouldThrow: Bool = false) {
        self.enabled = enabled
        self.shouldThrow = shouldThrow
    }

    func scrobbleEnabledServerIDs() async -> Set<UUID> {
        self.enabled
    }

    func scrobble(serverID: UUID, songID: String, submission: Bool) async throws {
        if self.shouldThrow {
            throw NSError(domain: "stub", code: 1)
        }
        self.scrobbleCalls.append(Call(serverID: serverID, songID: songID, submission: submission))
    }
}
