import Foundation
import Persistence
import Testing
@testable import UI

// MARK: - LibraryDestinationPersistenceTests

/// The selected sidebar destination must be persisted automatically as the user
/// navigates, so the app reopens where they left off rather than on a stale view
/// (e.g. always landing on Up Next). Previously only the folder/section sinks and
/// RootView's unreliable `.onDisappear` saved UI state, so a navigation away from
/// a stale destination never stuck. See issue: app always restarts on Up Next.
@Suite("LibraryViewModel Destination Persistence")
@MainActor
struct LibraryDestinationPersistenceTests {
    @Test("changing the destination auto-persists it (no explicit save) and restores on relaunch")
    func navigationAutoPersistsAcrossLaunch() async throws {
        let db = try await Database(location: .inMemory)
        let vm = LibraryViewModel(database: db, engine: MockTransport())

        // Simulate the user navigating to Songs. Note: NO explicit saveUIState()
        // call — this exercises the debounced `$selectedDestination` sink that the
        // fix adds. Use a non-default destination so the assertion is meaningful
        // (the fresh-VM default is `.songs`).
        vm.selectedDestination = .albums

        // Poll a freshly-constructed VM's restore until it observes the navigated
        // destination. The sink debounces 250 ms; 3 s is a generous ceiling.
        var restored: SidebarDestination = .songs
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            let probe = LibraryViewModel(database: db, engine: MockTransport())
            await probe.restoreUIState()
            restored = probe.selectedDestination
            if restored == .albums { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(restored == .albums, "navigated destination should auto-persist; got \(restored)")
    }
}
