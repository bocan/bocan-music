import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - LibraryViewModelClearQueueTests

/// Regression coverage for issue #260: the Playback menu's "Clear Queue"
/// command (Cmd-Shift-Delete) must confirm before wiping a built-up queue, while
/// a trivial queue (empty, or just the currently-playing track) still clears
/// without nagging. The decision lives in `resolveClearQueueRequest(itemCount:)`
/// so it can be exercised without spinning up a live `QueuePlayer`.
@Suite("LibraryViewModel Clear-Queue confirmation")
@MainActor
struct LibraryViewModelClearQueueTests {
    private func makeViewModel() async throws -> LibraryViewModel {
        let db = try await Database(location: .inMemory)
        return LibraryViewModel(database: db, engine: MockTransport())
    }

    @Test("confirmation flag defaults to false")
    func confirmationDefaultsFalse() async throws {
        let vm = try await self.makeViewModel()
        #expect(vm.clearQueueConfirmationPresented == false)
        #expect(vm.clearQueueItemCount == 0)
    }

    @Test("a trivial queue clears immediately without confirmation", arguments: [0, 1])
    func trivialQueueClearsImmediately(count: Int) async throws {
        let vm = try await self.makeViewModel()
        let clearNow = vm.resolveClearQueueRequest(itemCount: count)
        #expect(clearNow == true)
        #expect(vm.clearQueueConfirmationPresented == false)
    }

    @Test("a built-up queue raises a confirmation instead of clearing", arguments: [2, 3, 50])
    func builtUpQueueRaisesConfirmation(count: Int) async throws {
        let vm = try await self.makeViewModel()
        let clearNow = vm.resolveClearQueueRequest(itemCount: count)
        #expect(clearNow == false)
        #expect(vm.clearQueueConfirmationPresented == true)
        #expect(vm.clearQueueItemCount == count)
    }

    @Test("the threshold is two items")
    func thresholdIsTwo() {
        #expect(LibraryViewModel.clearQueueConfirmationThreshold == 2)
    }
}
