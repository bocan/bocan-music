import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - LibraryViewModelToastTests

/// ADR-007 audit M2 regression coverage for the toast surface added on
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

    @Test("Toast auto-dismisses after the timer")
    func autoDismiss() async throws {
        let vm = try await self.makeVM()
        vm.showToast(.init(text: "Hello"))
        #expect(vm.toast != nil)
        // The dismiss timer is ~2s. Poll with generous slack rather than a fixed
        // sleep + immediate assert, so a scheduler-starved run (the dismiss Task
        // delayed past a hard deadline) doesn't flake. See `make tests` load.
        try await self.pollUntil(timeout: 6.0) { vm.toast == nil }
        #expect(vm.toast == nil)
    }

    @Test("New toast replaces previous and resets the timer")
    func replacementResetsTimer() async throws {
        let vm = try await self.makeVM()
        vm.showToast(.init(text: "First"))
        try await Task.sleep(for: .milliseconds(1000))
        vm.showToast(.init(text: "Second"))
        // The first toast's stale dismiss timer (token-guarded) must NOT clear the
        // replacement. Wait past the point it would have fired; "Second" must hold.
        // This stays a fixed wait because it's a *negative* check: a toast that is
        // still showing cannot flake to nil early (timers never fire ahead of time).
        try await Task.sleep(for: .milliseconds(1200))
        #expect(vm.toast?.text == "Second")
        // The replacement's own timer then dismisses it; poll generously.
        try await self.pollUntil(timeout: 6.0) { vm.toast == nil }
        #expect(vm.toast == nil)
    }

    /// Polls `condition` until true or the allowance runs out, then returns. A
    /// subsequent `#expect` turns a timeout into an explicit failure.
    ///
    /// The allowance is counted in turns of 20 ms, not against the wall clock.
    /// The dismiss task and this test both need the main actor, so when other
    /// suites hold it for longer than `timeout` (seen in CI, 2026-10-01), a
    /// wall-clock deadline was already past when this resumed and the wait
    /// ended before the dismiss task had its turn. Each turn here yields the
    /// main actor, so time spent blocked uses none of the allowance.
    private func pollUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let turns = Int(timeout / 0.02)
        for _ in 0 ..< turns {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
