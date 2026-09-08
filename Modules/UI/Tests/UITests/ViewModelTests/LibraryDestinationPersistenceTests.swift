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

        // The sink debounces 250 ms and then writes "ui.state.v2". Wait for
        // that write by reading the settings store, a cheap query, rather than
        // by building a LibraryViewModel per poll: a full view model starts a
        // dozen observation tasks, so on a loaded parallel run the old loop
        // overshot its 3 s ceiling before the debounced save could land, and
        // failed CI twice on 2026-09-08. The ceiling is generous on purpose;
        // the test ends the moment the write appears.
        let settings = SettingsRepository(database: db)
        var saved: SidebarDestination?
        let deadline = Date().addingTimeInterval(15.0)
        while Date() < deadline {
            if let state = try await settings.get(UIStateV2.self, for: "ui.state.v2") {
                saved = state.selectedDestination
                if saved == .albums {
                    break
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(saved == .albums, "the debounced sink never persisted the navigation; last saved \(String(describing: saved))")

        // One probe, built after the write landed, proves the restore path.
        let probe = LibraryViewModel(database: db, engine: MockTransport())
        await probe.restoreUIState()
        #expect(probe.selectedDestination == .albums, "a fresh launch should restore the navigated destination")
    }
}
