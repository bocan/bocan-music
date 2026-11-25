import Foundation
import SwiftUI
import Testing
@testable import Persistence
@testable import UI

/// A released progress bar must not show the old position again before the
/// new one (#710). Covers the view model's seek and poll bookkeeping and the
/// shared drag release every scrubber uses.
@Suite("Scrub position (#710)")
@MainActor
struct NowPlayingScrubTests {
    private struct SeekFailure: Error {}

    /// Holds a scrubber's drag fraction the way a view's `@State` would.
    @MainActor
    private final class DragBox {
        var fraction: Double?
        var binding: Binding<Double?> {
            Binding(get: { self.fraction }, set: { self.fraction = $0 })
        }
    }

    private func makeViewModel() async throws -> (NowPlayingViewModel, MockTransport) {
        let engine = MockTransport()
        let db = try await Database(location: .inMemory)
        return (NowPlayingViewModel(engine: engine, database: db), engine)
    }

    @Test("position shows the target while the seek is on its way")
    func positionMovesBeforeSeekLands() async throws {
        let (vm, engine) = try await self.makeViewModel()
        engine.storedCurrentTime = 10
        engine.onSeek = { _ in
            let midSeek = await MainActor.run { vm.position }
            #expect(midSeek == 42)
        }
        await vm.scrub(to: 42)
        #expect(vm.position == 42)
    }

    @Test("a seek while paused moves the position (no poll runs then)")
    func pausedSeekMovesPosition() async throws {
        let (vm, engine) = try await self.makeViewModel()
        engine.storedCurrentTime = 10
        engine.emit(.paused)
        for _ in 0 ..< 100 where !vm.isPaused {
            await Task.yield()
        }
        try #require(vm.isPaused)
        await vm.scrub(to: 95)
        #expect(vm.position == 95)
    }

    @Test("a failed seek puts the position back where the engine is")
    func failedSeekRestoresEnginePosition() async throws {
        let (vm, engine) = try await self.makeViewModel()
        engine.storedCurrentTime = 10
        engine.seekError = SeekFailure()
        await vm.scrub(to: 42)
        #expect(vm.position == 10)
    }

    @Test("a poll that read the engine before or during a seek writes nothing")
    func stalePollIgnoredAcrossSeek() async throws {
        let (vm, engine) = try await self.makeViewModel()
        engine.storedCurrentTime = 10
        let epochBeforeSeek = vm.positionPollEpoch
        engine.onSeek = { _ in
            await MainActor.run {
                vm.applyPolledPosition(10, duration: 0, readAtEpoch: vm.positionPollEpoch)
                #expect(vm.position == 42)
            }
        }
        await vm.scrub(to: 42)

        vm.applyPolledPosition(10, duration: 200, readAtEpoch: epochBeforeSeek)
        #expect(vm.position == 42)
        #expect(vm.duration == 200, "the duration is not stale and still lands")

        // A poll that starts after the seek lands as normal.
        vm.applyPolledPosition(43, duration: 0, readAtEpoch: vm.positionPollEpoch)
        #expect(vm.position == 43)
    }

    @Test("release keeps the drag until the seek lands, then lets go")
    func releaseHoldsDragUntilSeekLands() async throws {
        let (vm, engine) = try await self.makeViewModel()
        let drag = DragBox()
        drag.fraction = 0.5
        engine.onSeek = { _ in
            let held = await MainActor.run { drag.fraction }
            #expect(held == 0.5)
        }
        await ScrubberDrag.release(drag.binding, nowPlaying: vm)
        #expect(engine.seekTarget != nil)
        #expect(drag.fraction == nil)
    }

    @Test("release leaves a new drag that began during the seek alone")
    func releaseKeepsNewerDrag() async throws {
        let (vm, engine) = try await self.makeViewModel()
        let drag = DragBox()
        drag.fraction = 0.5
        engine.onSeek = { _ in
            await MainActor.run { drag.fraction = 0.8 }
        }
        await ScrubberDrag.release(drag.binding, nowPlaying: vm)
        #expect(drag.fraction == 0.8)
    }

    @Test("release with no drag held does not seek")
    func releaseWithoutDragDoesNothing() async throws {
        let (vm, engine) = try await self.makeViewModel()
        await ScrubberDrag.release(DragBox().binding, nowPlaying: vm)
        #expect(engine.seekTarget == nil)
    }
}
