import AppKit
import Foundation
import Testing
@testable import UI

// MARK: - Stub

private final class StubAnnotationDelivery: SubsonicAnnotationDelivering, @unchecked Sendable {
    enum Call: Equatable {
        case star(UUID, String)
        case unstar(UUID, String)
        case setRating(UUID, String, Int)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private let stream: AsyncStream<SubsonicAnnotationFailure>
    private let continuation: AsyncStream<SubsonicAnnotationFailure>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<SubsonicAnnotationFailure>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    var calls: [Call] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._calls
    }

    private func append(_ call: Call) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self._calls.append(call)
    }

    func annotationFailures() -> AsyncStream<SubsonicAnnotationFailure> {
        self.stream
    }

    func emit(_ failure: SubsonicAnnotationFailure) {
        self.continuation.yield(failure)
    }

    func star(serverID: UUID, songID: String) async {
        self.append(.star(serverID, songID))
    }

    func unstar(serverID: UUID, songID: String) async {
        self.append(.unstar(serverID, songID))
    }

    func setRating(serverID: UUID, songID: String, rating: Int) async {
        self.append(.setRating(serverID, songID, rating))
    }
}

/// Stands in for a row-owning view model: counts the rebuild calls the
/// coordinator makes (#475).
@MainActor
private final class SpyAnnotationObserver: SubsonicAnnotationObserving {
    private(set) var changes = 0

    func annotationOverridesDidChange() {
        self.changes += 1
    }
}

// MARK: - Haptics isolation

/// Runs `body` with the process-global haptic seam silenced, and restores it.
///
/// `Haptics.performPattern` is one closure for the whole process.
/// `NowPlayingViewModelTests.transportHaptics` installs a recorder into it and
/// keeps it installed across suspension points, then asserts that no
/// level-change haptic was performed. A star or rating written by any
/// concurrently running test lands in that recorder and fails it, so a test
/// that writes one for some other reason silences the seam around the call.
/// The swap never suspends, so no other `@MainActor` test can observe it.
/// A test that is *about* the haptic installs its own recorder instead.
@MainActor
func silencingHaptics<T>(_ body: () -> T) -> T {
    let original = Haptics.performPattern
    Haptics.performPattern = { _ in }
    defer { Haptics.performPattern = original }
    return body()
}

// MARK: - Tests

@Suite("SubsonicAnnotationCoordinator")
@MainActor
struct SubsonicAnnotationCoordinatorTests {
    private let serverID = UUID()

    private func waitForCalls(_ stub: StubAnnotationDelivery, count: Int) async {
        for _ in 0 ..< 50 {
            if stub.calls.count >= count {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("every override write tells the row owners to rebuild (#475)")
    func everyOverrideWriteNotifiesObservers() async {
        let stub = StubAnnotationDelivery()
        let coord = SubsonicAnnotationCoordinator(delivery: stub)
        let observer = SpyAnnotationObserver()
        coord.addObserver(observer)
        #expect(observer.changes == 0, "registering is not a change")

        silencingHaptics {
            coord.toggleStar(songID: "s1", serverID: self.serverID, currentlyStarred: false)
        }
        #expect(observer.changes == 1, "a star override is a write")

        silencingHaptics {
            coord.toggleStar(songID: "s1", serverID: self.serverID, currentlyStarred: true)
        }
        #expect(observer.changes == 2, "clearing it is a write too")

        silencingHaptics {
            coord.setRating(songID: "s1", serverID: self.serverID, newRating: 4, previousRating: nil)
        }
        #expect(observer.changes == 3, "a rating override is a write")
        await self.waitForCalls(stub, count: 3)
    }

    @Test("an observer is registered once and held weakly")
    func observerRegistrationIsIdempotentAndWeak() async {
        let stub = StubAnnotationDelivery()
        let coord = SubsonicAnnotationCoordinator(delivery: stub)
        let observer = SpyAnnotationObserver()
        coord.addObserver(observer)
        coord.addObserver(observer)

        silencingHaptics {
            coord.toggleStar(songID: "s1", serverID: self.serverID, currentlyStarred: false)
        }
        #expect(observer.changes == 1, "registering twice must not notify twice")

        // A destination that goes away deregisters itself: no teardown call,
        // and no crash on the next write.
        do {
            let transient = SpyAnnotationObserver()
            coord.addObserver(transient)
        }
        silencingHaptics {
            coord.toggleStar(songID: "s2", serverID: self.serverID, currentlyStarred: false)
        }
        #expect(observer.changes == 2)
        await self.waitForCalls(stub, count: 2)
    }

    @Test("toggleStar updates override immediately and dispatches star")
    func toggleStarOptimistic() async {
        let stub = StubAnnotationDelivery()
        let coord = SubsonicAnnotationCoordinator(delivery: stub)
        #expect(coord.isStarred(songID: "s1", serverStarred: nil) == false)
        silencingHaptics {
            coord.toggleStar(songID: "s1", serverID: self.serverID, currentlyStarred: false)
        }
        #expect(coord.isStarred(songID: "s1", serverStarred: nil) == true)
        await self.waitForCalls(stub, count: 1)
        #expect(stub.calls == [.star(self.serverID, "s1")])
    }

    @Test("toggleStar on currently-starred song dispatches unstar")
    func toggleStarUnstars() async {
        let stub = StubAnnotationDelivery()
        let coord = SubsonicAnnotationCoordinator(delivery: stub)
        silencingHaptics {
            coord.toggleStar(songID: "s1", serverID: self.serverID, currentlyStarred: true)
        }
        #expect(coord.isStarred(songID: "s1", serverStarred: Date()) == false)
        await self.waitForCalls(stub, count: 1)
        #expect(stub.calls == [.unstar(self.serverID, "s1")])
    }

    @Test("setRating clamps to 0...5 and dispatches setRating")
    func setRatingDispatches() async {
        let stub = StubAnnotationDelivery()
        let coord = SubsonicAnnotationCoordinator(delivery: stub)
        silencingHaptics {
            coord.setRating(songID: "s1", serverID: self.serverID, newRating: 9, previousRating: nil)
        }
        #expect(coord.rating(songID: "s1", serverRating: nil) == 5)
        await self.waitForCalls(stub, count: 1)
        #expect(stub.calls == [.setRating(self.serverID, "s1", 5)])
    }

    @Test("failure event rolls star back to original value")
    func failureRollbackStar() async {
        let stub = StubAnnotationDelivery()
        let coord = SubsonicAnnotationCoordinator(delivery: stub)
        silencingHaptics {
            coord.toggleStar(songID: "s1", serverID: self.serverID, currentlyStarred: false)
        }
        #expect(coord.isStarred(songID: "s1", serverStarred: nil) == true)
        stub.emit(SubsonicAnnotationFailure(serverID: self.serverID, songID: "s1", reason: "boom"))
        for _ in 0 ..< 50 {
            if coord.isStarred(songID: "s1", serverStarred: nil) == false {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(coord.isStarred(songID: "s1", serverStarred: nil) == false)
    }

    @Test("failure event rolls rating back to previous value")
    func failureRollbackRating() async {
        let stub = StubAnnotationDelivery()
        let coord = SubsonicAnnotationCoordinator(delivery: stub)
        silencingHaptics {
            coord.setRating(songID: "s1", serverID: self.serverID, newRating: 4, previousRating: 2)
        }
        #expect(coord.rating(songID: "s1", serverRating: 2) == 4)
        stub.emit(SubsonicAnnotationFailure(serverID: self.serverID, songID: "s1", reason: "boom"))
        for _ in 0 ..< 50 {
            if coord.rating(songID: "s1", serverRating: 2) == 2 {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(coord.rating(songID: "s1", serverRating: 2) == 2)
    }

    @Test("failure for unrelated song does not affect other overrides")
    func failureIsolatedToSong() async {
        let stub = StubAnnotationDelivery()
        let coord = SubsonicAnnotationCoordinator(delivery: stub)
        silencingHaptics {
            coord.toggleStar(songID: "s1", serverID: self.serverID, currentlyStarred: false)
            coord.toggleStar(songID: "s2", serverID: self.serverID, currentlyStarred: false)
        }
        stub.emit(SubsonicAnnotationFailure(serverID: self.serverID, songID: "s1", reason: "boom"))
        for _ in 0 ..< 50 {
            if coord.isStarred(songID: "s1", serverStarred: nil) == false {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(coord.isStarred(songID: "s1", serverStarred: nil) == false)
        #expect(coord.isStarred(songID: "s2", serverStarred: nil) == true)
    }

    @Test("toggleStar and setRating perform a level-change haptic (#330)")
    func annotationActionsPerformHaptic() {
        let stub = StubAnnotationDelivery()
        let coord = SubsonicAnnotationCoordinator(delivery: stub)
        var patterns: [NSHapticFeedbackManager.FeedbackPattern] = []
        let original = Haptics.performPattern
        defer { Haptics.performPattern = original }
        Haptics.performPattern = { patterns.append($0) }
        coord.toggleStar(songID: "s1", serverID: self.serverID, currentlyStarred: false)
        coord.setRating(songID: "s1", serverID: self.serverID, newRating: 3, previousRating: nil)
        #expect(patterns == [.levelChange, .levelChange])
    }

    @Test("reset(songID:) drops both star and rating overrides")
    func resetDropsOverrides() {
        let stub = StubAnnotationDelivery()
        let coord = SubsonicAnnotationCoordinator(delivery: stub)
        silencingHaptics {
            coord.toggleStar(songID: "s1", serverID: self.serverID, currentlyStarred: false)
            coord.setRating(songID: "s1", serverID: self.serverID, newRating: 3, previousRating: nil)
        }
        coord.reset(songID: "s1")
        #expect(coord.isStarred(songID: "s1", serverStarred: nil) == false)
        #expect(coord.rating(songID: "s1", serverRating: nil) == 0)
    }
}
