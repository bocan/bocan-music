import Foundation
import Jellyfin
import Testing
@testable import UI

// MARK: - Stub

/// Records each favourite write and lets a test push a failure.
private final class StubJellyfinAnnotations: JellyfinAnnotationDelivering, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(itemID: String, isFavorite: Bool)] = []
    private let (stream, continuation) = AsyncStream<JellyfinAnnotationFailure>.makeStream()

    var calls: [(itemID: String, isFavorite: Bool)] {
        self.lock.withLock { self.recorded }
    }

    func setFavorite(serverID _: UUID, itemID: String, isFavorite: Bool) async {
        self.lock.withLock { self.recorded.append((itemID, isFavorite)) }
    }

    func annotationFailures() async -> AsyncStream<JellyfinAnnotationFailure> {
        self.stream
    }

    func fail(serverID: UUID, itemID: String) {
        self.continuation.yield(JellyfinAnnotationFailure(serverID: serverID, itemID: itemID, reason: "offline"))
    }
}

// MARK: - Tests

@Suite("JellyfinAnnotationCoordinator (ADR-097)")
@MainActor
struct JellyfinAnnotationCoordinatorTests {
    private let serverID = UUID()

    private func song(_ id: String, starred: Bool = false) -> JellyfinSong {
        JellyfinSong(id: id, title: "Song \(id)", isStarred: starred)
    }

    @Test("a click shows the new value at once and sends the write")
    func toggleIsOptimistic() async {
        let stub = StubJellyfinAnnotations()
        let coordinator = JellyfinAnnotationCoordinator(delivery: stub)

        silencingHaptics {
            coordinator.toggleStar(serverID: self.serverID, itemID: "a", currentlyStarred: false)
        }

        #expect(coordinator.isStarred(serverID: self.serverID, itemID: "a", serverValue: false))
        #expect(await waitUntil { stub.calls.count == 1 })
        #expect(stub.calls.first?.itemID == "a")
        #expect(stub.calls.first?.isFavorite == true)
    }

    @Test("a failed write puts the old value back")
    func failureRollsBack() async {
        let stub = StubJellyfinAnnotations()
        let coordinator = JellyfinAnnotationCoordinator(delivery: stub)
        silencingHaptics {
            coordinator.toggleStar(serverID: self.serverID, itemID: "a", currentlyStarred: false)
        }

        stub.fail(serverID: self.serverID, itemID: "a")

        #expect(await waitUntil { !coordinator.isStarred(serverID: self.serverID, itemID: "a", serverValue: false) })
    }

    @Test("an override belongs to one server, never to the same id on another")
    func overridesArePerServer() {
        let coordinator = JellyfinAnnotationCoordinator(delivery: StubJellyfinAnnotations())
        silencingHaptics {
            coordinator.toggleStar(serverID: self.serverID, itemID: "a", currentlyStarred: false)
        }
        #expect(coordinator.isStarred(serverID: self.serverID, itemID: "a", serverValue: false))
        #expect(!coordinator.isStarred(serverID: UUID(), itemID: "a", serverValue: false))
    }

    @Test("a song table's rows follow the click, through the observer")
    func listModelRowsFollow() {
        let coordinator = JellyfinAnnotationCoordinator(delivery: StubJellyfinAnnotations())
        let model = JellyfinSongListModel(serverID: self.serverID)
        model.songs = [self.song("a"), self.song("b", starred: true)]
        model.attach(coordinator)
        let versionBefore = model.rowsVersion

        silencingHaptics {
            coordinator.toggleStar(serverID: self.serverID, itemID: "a", currentlyStarred: false)
            coordinator.toggleStar(serverID: self.serverID, itemID: "b", currentlyStarred: true)
        }

        #expect(model.rows.map(\.starred) == [true, false])
        #expect(model.rowsVersion > versionBefore)
        // The songs themselves keep the server's values; only the rows show the click.
        #expect(model.songs.map(\.isStarred) == [false, true])
    }

    @Test("attaching the same coordinator twice registers once")
    func attachIsIdempotent() {
        let coordinator = JellyfinAnnotationCoordinator(delivery: StubJellyfinAnnotations())
        let model = JellyfinSongListModel(serverID: self.serverID)
        model.songs = [self.song("a")]
        model.attach(coordinator)
        let version = model.rowsVersion
        model.attach(coordinator)
        #expect(model.rowsVersion == version)
    }

    @Test("with no coordinator the star click does nothing and does not crash")
    func noCoordinator() {
        let source = JellyfinSourceModel()
        #expect(source.annotations == nil)
        source.toggleStar(JellyfinSongTableRow(song: self.song("a"), serverID: self.serverID, serverName: "Home"))
    }
}
