import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - LibraryViewModelToastTests

/// Phase 5.5 audit M2 regression coverage for the toast surface added on
/// ``LibraryViewModel``. The full rescan-success integration path requires a
/// real ``LibraryScanner`` and is exercised in the snapshot tests; here we
/// pin down the toast contract itself so future refactors can't quietly
/// regress the auto-dismiss timer or replacement behaviour.
@Suite("LibraryViewModel Toast Tests")
@MainActor
struct LibraryViewModelToastTests {
    private func makeVM() async throws -> LibraryViewModel {
        let db = try await Database(location: .inMemory)
        return LibraryViewModel(database: db, engine: MockTransport())
    }

    @Test("showToast publishes the message")
    func showToastPublishes() async throws {
        let vm = try await self.makeVM()
        vm.showToast(.init(text: "Re-scanned “Song”", kind: .success))
        #expect(vm.toast?.text == "Re-scanned “Song”")
        #expect(vm.toast?.kind == .success)
    }

    @Test("Toast auto-dismisses after 2 seconds")
    func autoDismiss() async throws {
        let vm = try await self.makeVM()
        vm.showToast(.init(text: "Hello"))
        #expect(vm.toast != nil)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(vm.toast == nil)
    }

    @Test("New toast replaces previous and resets the timer")
    func replacementResetsTimer() async throws {
        let vm = try await self.makeVM()
        vm.showToast(.init(text: "First"))
        try await Task.sleep(for: .milliseconds(1000))
        vm.showToast(.init(text: "Second"))
        // The first toast's dismiss timer must NOT fire 1s from now.
        try await Task.sleep(for: .milliseconds(1200))
        #expect(vm.toast?.text == "Second")
        // But the second one's timer should fire shortly after.
        try await Task.sleep(for: .milliseconds(1000))
        #expect(vm.toast == nil)
    }
}
